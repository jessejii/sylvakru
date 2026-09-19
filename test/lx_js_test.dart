// 自定义源脚本运行时的验收测试。
//
// Windows 上 flutter_js 走 QuickJS 的 dart:ffi，需要先让 `quickjs_c_bridge.dll`
// 可被找到 —— 没做过 `flutter build windows` 时，把插件自带的目录加进 PATH 即可：
//
//   $env:path += ";<pub cache>\flutter_js-0.8.7\windows\shared"
//   flutter test test/lx_js_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/base/app.dart' as app;
import 'package:sylvakru/base/services/logger.dart';
import 'package:sylvakru/online_music/lx_js/lx_js_bridge.dart';
import 'package:sylvakru/online_music/lx_js/lx_js_example.dart';

const String _aesKey = '2b7e151628aed2a6abf7158809cf4f3c';
const String _aesIv = '000102030405060708090a0b0c0d0e0f';
const String _aesPlain = '6bc1bee22e409f96e93d7e117393172a';
// NIST AES-128-CBC 标准测试向量。
const String _aesCipher = '7649abac8119b246cee98e9b12e9197d';

/// 把真实脚本的服务端地址换成本地假接口，其余一字不动。
String _juheAt(String base) =>
    lxJuheSampleScript.replaceFirst('https://api.music.lerd.dpdns.org', base);

/// 探测脚本：把 lx.utils 的结果拼进一个合规 url 带回来。
const String _probeScript = r'''
const { EVENT_NAMES, on, send, utils } = globalThis.lx;
const hex = (h) => utils.buffer.from(h, 'hex');
on(EVENT_NAMES.request, async ({ info }) => {
  const t = info.type;
  const m = info.musicInfo;
  let v;
  if (t === 'md5') v = utils.crypto.md5(m.text);
  else if (t === 'aes') v = utils.crypto.aesEncrypt(hex(m.pt), 'aes-128-cbc', hex(m.key), hex(m.iv)).toString('hex');
  else if (t === 'aesMode') { try { utils.crypto.aesEncrypt(hex(m.pt), 'aes-128-gcm', hex(m.key), hex(m.iv)); v = 'no-error'; } catch (e) { v = 'error'; } }
  else if (t === 'rand') v = String(utils.crypto.randomBytes(16).length);
  else if (t === 'deflate') v = (await utils.zlib.deflate(utils.buffer.from(m.text))).toString('base64');
  else if (t === 'inflate') v = (await utils.zlib.inflate(utils.buffer.from(m.b64, 'base64'))).toString();
  else if (t === 'b64') v = utils.buffer.from(m.text).toString('base64');
  else if (t === 'atob') v = String(btoa(atob(m.b64)) === m.b64);
  else v = 'none';
  return 'http://probe.local/' + encodeURIComponent(v);
});
send(EVENT_NAMES.inited, { sources: { probe: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } } });
''';

/// 超时 / abort 脚本。
const String _netScript = r'''
const { EVENT_NAMES, on, send, request } = globalThis.lx;
on(EVENT_NAMES.request, async ({ info }) => {
  const url = info.musicInfo.url;
  if (info.type === 'timeout') {
    await new Promise((resolve, reject) => {
      request(url, { method: 'GET', timeout: 100 }, (err) => err ? reject(err) : resolve(null));
    });
    return 'http://never.local/x';
  }
  if (info.type === 'abort') {
    await new Promise((resolve, reject) => {
      const abort = request(url, { method: 'GET' }, (err) => err ? reject(new Error('aborted')) : resolve(null));
      setTimeout(() => abort(), 30);
    });
    return 'http://never.local/x';
  }
  return 'http://probe.local/ok';
});
send(EVENT_NAMES.inited, { sources: { probe: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } } });
''';

late HttpServer _server;
late String _base;

Future<void> _reply(HttpRequest request, Object body) async {
  request.response.statusCode = 200;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

Future<void> _handle(HttpRequest request) async {
  switch (request.uri.path) {
    case '/init.conf':
      await _reply(request, {
        'code': 200,
        'data': {
          'update': {'version': 1, 'log': ''},
          'init': {
            'sources': {
              'kw': {
                'type': 'music',
                'actions': ['musicUrl', 'lyric'],
                'qualitys': ['128k', '320k', 'flac', 'unknown'],
              },
              'mg': {
                'type': 'music',
                'actions': ['musicUrl'],
                'qualitys': ['128k', 'flac'],
              },
              'bad': {
                'type': 'music',
                'actions': ['musicUrl'],
                'qualitys': ['128k'],
              },
              'no-url': {
                'type': 'music',
                'actions': ['lyric'],
                'qualitys': ['128k'],
              },
            },
          },
        },
      });
    case '/kw':
      await _reply(request, {
        'code': 200,
        'data': {'url': '$_base/kw.mp3'},
      });
    case '/mg':
      // 真实脚本的 303 分支：再请求一次并校验。
      await _reply(request, {
        'code': 303,
        'data': {
          'request': {
            'url': '$_base/check',
            'options': {'method': 'GET', 'headers': {}},
          },
          'response': {
            'check': {
              'key': ['body', 'code'],
              'value': 200,
            },
            'url': ['body', 'data', 'url'],
          },
        },
      });
    case '/check':
      await _reply(request, {
        'code': 200,
        'data': {'url': '$_base/mg.mp3'},
      });
    case '/bad':
      await _reply(request, {
        'code': 200,
        'data': {'url': 'ftp://evil.example.com/x.mp3'},
      });
    case '/slow':
      await Future<void>.delayed(const Duration(seconds: 5));
      await _reply(request, {'code': 200});
    default:
      await _reply(request, {'code': 404});
  }
}

Map<String, dynamic> _musicInfo([String source = 'kw']) => {
  'name': '晴天',
  'singer': '周杰伦',
  'source': source,
  'songmid': '123456',
  'interval': '04:29',
  'albumName': '叶惠美',
  'img': '',
  'typeUrl': <String, dynamic>{},
  'albumId': '0',
};

/// probe 脚本把结果拼在 url 尾部，这里取回来。
String _probeValue(String url) {
  expect(url.startsWith('http://probe.local/'), isTrue);
  return Uri.decodeComponent(url.substring('http://probe.local/'.length));
}

void main() {
  setUpAll(() async {
    app.appSupportDir = await Directory.systemTemp.createTemp('lx_js_test');
    await logger.init();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) => unawaited(_handle(request)));
    _base = 'http://127.0.0.1:${_server.port}';
  });

  tearDownAll(() async {
    await _server.close(force: true);
  });

  test('真实脚本：inited 拿到音源表', () async {
    final engine = await LxJsEngine.load(script: _juheAt(_base));
    addTearDown(engine.dispose);

    expect(engine.sources.keys, containsAll(['kw', 'mg', 'bad']));
    // 只留声明过的、且带 musicUrl 的音源；未知音质被过滤。
    expect(engine.sources['kw']!.qualitys, ['128k', '320k', 'flac']);
    expect(engine.sources['kw']!.actions, ['musicUrl', 'lyric']);
    expect(engine.sources.containsKey('no-url'), isFalse);
  });

  test('真实脚本：getMusicUrl 走 Dio 拿到合规直链', () async {
    final engine = await LxJsEngine.load(script: _juheAt(_base));
    addTearDown(engine.dispose);

    final url = await engine.getMusicUrl(
      source: 'kw',
      musicInfo: _musicInfo('kw'),
      quality: '128k',
    );
    expect(url, '$_base/kw.mp3');
  });

  test('真实脚本：303 二次校验分支', () async {
    final engine = await LxJsEngine.load(script: _juheAt(_base));
    addTearDown(engine.dispose);

    final url = await engine.getMusicUrl(
      source: 'mg',
      musicInfo: _musicInfo('mg'),
      quality: 'flac',
    );
    expect(url, '$_base/mg.mp3');
  });

  test('直链不是 http(s) 时被拒绝', () async {
    final engine = await LxJsEngine.load(script: _juheAt(_base));
    addTearDown(engine.dispose);

    await expectLater(
      engine.getMusicUrl(
        source: 'bad',
        musicInfo: _musicInfo('bad'),
        quality: '128k',
      ),
      throwsA(isA<LxJsException>()),
    );
  });

  test('host 白名单外的请求被拒绝（防 SSRF）', () async {
    await expectLater(
      LxJsEngine.load(
        script: _juheAt(_base),
        allowedHosts: {'example.com'},
        initTimeout: const Duration(seconds: 3),
      ),
      throwsA(isA<LxJsException>()),
    );
  });

  test('lx.request 超时与 abort', () async {
    final engine = await LxJsEngine.load(script: _netScript);
    addTearDown(engine.dispose);

    await expectLater(
      engine.getMusicUrl(
        source: 'probe',
        musicInfo: {'url': '$_base/slow'},
        quality: 'timeout',
      ),
      throwsA(isA<LxJsException>()),
    );

    await expectLater(
      engine.getMusicUrl(
        source: 'probe',
        musicInfo: {'url': '$_base/slow'},
        quality: 'abort',
      ),
      throwsA(isA<LxJsException>()),
    );
  });

  test('lx.utils.crypto / zlib / buffer', () async {
    final engine = await LxJsEngine.load(script: _probeScript);
    addTearDown(engine.dispose);

    Future<String> probe(String type, Map<String, dynamic> musicInfo) async =>
        _probeValue(
          await engine.getMusicUrl(
            source: 'probe',
            musicInfo: musicInfo,
            quality: type,
          ),
        );

    expect(await probe('md5', {'text': 'abc'}), '900150983cd24fb0d6963f7d28e17f72');
    // 明文正好一块，Node 的 createCipheriv 会再补一整块 PKCS7，所以是 32 字节。
    final aes = await probe('aes', {'pt': _aesPlain, 'key': _aesKey, 'iv': _aesIv});
    expect(aes.length, 64);
    expect(aes.startsWith(_aesCipher), isTrue);
    expect(await probe('aesMode', {'pt': _aesPlain, 'key': _aesKey, 'iv': _aesIv}), 'error');
    expect(await probe('rand', {}), '16');
    expect(await probe('b64', {'text': '中文abc'}), base64Encode(utf8.encode('中文abc')));
    expect(await probe('atob', {'b64': base64Encode(utf8.encode('中文abc'))}), 'true');

    final deflated = await probe('deflate', {'text': 'hello lx'});
    expect(
      await probe('inflate', {'b64': deflated}),
      'hello lx',
    );
  });

  test(
    '真实脚本 + 真实外网接口',
    () async {
      final engine = await LxJsEngine.load(script: lxJuheSampleScript);
      addTearDown(engine.dispose);
      final url = await engine.getMusicUrl(
        source: engine.sources.keys.first,
        musicInfo: _musicInfo(engine.sources.keys.first),
        quality: '128k',
      );
      expect(url.startsWith('http'), isTrue);
    },
    skip: '需要外网访问脚本自带的接口',
  );
}
