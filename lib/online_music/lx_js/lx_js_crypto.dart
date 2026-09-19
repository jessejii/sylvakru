// `lx.utils.crypto` / `lx.utils.zlib` 的 Dart 后端。
//
// 同步语义：JS 侧 `sendMessage` 是同步的，Dart 回调的返回值会原路回到 JS，
// 所以这里全部是纯计算，不出现 await。二进制统一走 base64（见 lx_js_polyfill.dart）。
//
// 对齐 preload.js 的 Node 语义：
//   aesEncrypt(buffer, mode, key, iv)  -> createCipheriv，块模式带 PKCS7
//   rsaEncrypt(buffer, key)            -> RSA_NO_PADDING，左侧补零到 128 字节
//   randomBytes(size) / md5(str)
//   inflate / deflate                  -> zlib（inflate 失败回退 raw deflate）

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';

/// 自定义源脚本/桥接层的错误。
class LxJsException implements Exception {
  LxJsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// JS 传过来的二进制：要么是 `{'__lx_b': base64}`，要么是字符串/字节数组。
Uint8List lxJsBytes(Object? value) {
  if (value is Map) {
    final encoded = value['__lx_b'];
    if (encoded is String) return base64Decode(encoded);
    return Uint8List(0);
  }
  if (value is String) return utf8.encode(value);
  if (value is List) {
    return Uint8List.fromList(
      value.map((e) => (e is num ? e.toInt() : 0) & 0xff).toList(),
    );
  }
  return Uint8List(0);
}

/// 分发 JS 的 `lx.utils.*` 调用。返回可直接 JSON 编码的结果。
/// 约定：二进制结果用 `{'b64': ...}`，十六进制用 `{'hex': ...}`。
Map<String, Object?> callLxJsUtil(String fn, List<Object?> args) {
  try {
    return switch (fn) {
      'aesEncrypt' => _aesEncrypt(args),
      'rsaEncrypt' => {'b64': base64Encode(_rsaEncrypt(args))},
      'randomBytes' => {'b64': base64Encode(_randomBytes(args))},
      'md5' => {'hex': _md5(args)},
      'inflate' => {'b64': base64Encode(_inflate(args))},
      'deflate' => {'b64': base64Encode(_deflate(args))},
      _ => throw LxJsException('未实现的 lx.utils 调用: $fn'),
    };
  } on LxJsException catch (e) {
    return {'ok': false, 'error': e.message};
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

Map<String, Object?> _aesEncrypt(List<Object?> args) {
  final data = lxJsBytes(args.isEmpty ? null : args[0]);
  final mode = '${args.length > 1 ? args[1] : ''}'.toLowerCase();
  final key = lxJsBytes(args.length > 2 ? args[2] : null);
  final iv = args.length > 3 && args[3] != null
      ? lxJsBytes(args[3])
      : Uint8List(16);

  final (AESMode aesMode, String? padding) = switch (mode) {
    _ when mode.endsWith('-cbc') => (AESMode.cbc, 'PKCS7'),
    _ when mode.endsWith('-ecb') => (AESMode.ecb, 'PKCS7'),
    _ when mode.endsWith('-ctr') => (AESMode.sic, null),
    _ => throw LxJsException('不支持的 AES 模式: $mode（仅 cbc/ecb/ctr）'),
  };

  final encrypter = Encrypter(AES(Key(key), mode: aesMode, padding: padding));
  return {'b64': base64Encode(encrypter.encryptBytes(data, iv: IV(iv)).bytes)};
}

Uint8List _rsaEncrypt(List<Object?> args) {
  final data = lxJsBytes(args.isEmpty ? null : args[0]);
  final key = '${args.length > 1 ? args[1] : ''}';
  // Node 的 RSA_NO_PADDING：输入左侧补零到 128 字节。
  if (data.length > 128) throw LxJsException('rsaEncrypt: 数据超过 128 字节');
  final padded = Uint8List(128)..setAll(128 - data.length, data);

  final (BigInt modulus, BigInt exponent) = parseRsaPublicKey(key);
  final encrypted = lxBigIntFromBytes(padded).modPow(exponent, modulus);
  return lxBytesFromBigInt(encrypted, (modulus.bitLength + 7) ~/ 8);
}

Uint8List _randomBytes(List<Object?> args) {
  final size = (args.isEmpty ? null : args[0]) is num
      ? (args[0]! as num).toInt()
      : int.tryParse('${args.isEmpty ? '' : args[0]}') ?? 0;
  if (size <= 0 || size > 4096) throw LxJsException('randomBytes: 长度不合法');
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(size, (_) => random.nextInt(256)),
  );
}

String _md5(List<Object?> args) {
  final value = args.isEmpty ? null : args[0];
  final bytes = value is Map ? lxJsBytes(value) : utf8.encode('$value');
  return md5.convert(bytes).toString();
}

Uint8List _inflate(List<Object?> args) => _zlibDecode(lxJsBytes(args.isEmpty ? null : args[0]));

Uint8List _deflate(List<Object?> args) => Uint8List.fromList(
      ZLibCodec().encode(lxJsBytes(args.isEmpty ? null : args[0])),
    );

/// Node 的 `zlib.inflate`（zlib 头）。有些源给的是裸 deflate，退一层再试。
Uint8List _zlibDecode(Uint8List data) {
  try {
    return Uint8List.fromList(ZLibCodec().decode(data));
  } catch (_) {
    return Uint8List.fromList(ZLibCodec(raw: true).decode(data));
  }
}

// ---------------------------------------------------------------------------
// RSA 公钥解析
// ---------------------------------------------------------------------------

/// 解析 PEM（`-----BEGIN PUBLIC KEY-----`）或 base64(DER) 形式的 RSA 公钥，
/// 返回 (n, e)。ponytail: 手写最小 DER 解析，避免为一个函数拉 asn1lib 依赖。
(BigInt, BigInt) parseRsaPublicKey(String key) {
  final body = key.contains('BEGIN')
      ? key
          .split(RegExp(r'-----'))
          .where((part) => part.trim().isNotEmpty && !part.contains(' '))
          .join()
          .replaceAll(RegExp(r'\s'), '')
      : key.replaceAll(RegExp(r'\s'), '');
  final Uint8List der;
  try {
    der = base64Decode(body);
  } catch (_) {
    throw LxJsException('rsaEncrypt: 公钥不是合法的 base64');
  }
  try {
    // SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING }
    final spki = _tlv(der, 0);
    final alg = _tlv(der, spki.$2);
    final bits = _tlv(der, alg.$2 + alg.$3);
    var p = bits.$2 + 1; // BIT STRING 的首字节是 unused bits
    final inner = _tlv(der, p);
    p = inner.$2;
    final nTlv = _tlv(der, p);
    final eTlv = _tlv(der, nTlv.$2 + nTlv.$3);
    return (_integer(der, nTlv.$2, nTlv.$3), _integer(der, eTlv.$2, eTlv.$3));
  } catch (_) {
    throw LxJsException('rsaEncrypt: 公钥解析失败');
  }
}

/// 读取一个 TLV，返回 (tag, 起始位置, 长度)。
(int, int, int) _tlv(Uint8List b, int offset) {
  if (offset + 2 > b.length) throw const FormatException('DER 越界');
  final tag = b[offset];
  var cursor = offset + 1;
  var length = b[cursor++];
  if (length & 0x80 != 0) {
    final count = length & 0x7f;
    if (cursor + count > b.length) throw const FormatException('DER 越界');
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | b[cursor++];
    }
  }
  return (tag, cursor, length);
}

BigInt _integer(Uint8List b, int start, int length) =>
    lxBigIntFromBytes(Uint8List.sublistView(b, start, start + length));

/// 大端字节 -> 非负 BigInt。
BigInt lxBigIntFromBytes(Uint8List bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

/// 非负 BigInt -> 定长大端字节。
Uint8List lxBytesFromBigInt(BigInt value, int length) {
  final out = Uint8List(length);
  var rest = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (rest & BigInt.from(0xff)).toInt();
    rest >>= 8;
  }
  return out;
}
