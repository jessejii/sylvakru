// lx-music 自定义源运行时桥：注入 `lx`，跑用户脚本，用 Dio 发请求，取 musicUrl。
//
// 对齐的两份宿主实现：
//   * preload.js  —— `lx` 的对象面、`handleInit`、`handleRequest` 的校验
//   * rendererEvent.ts —— requestQueue + 20s 超时 + cancelRequest
//
// 通道（flutter_js 0.8.7 的实际能力）：
//   JS -> Dart：`sendMessage('lx_bridge', json)`，同步，且 Dart 回调的返回值会回到 JS。
//   Dart -> JS：`runtime.evaluate("__lx_dispatch('<base64>')")`，用来分发取链请求和回灌 HTTP 结果。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:sylvakru/base/services/logger.dart';
import 'package:sylvakru/online_music/lx_js/lx_js_crypto.dart';
import 'package:sylvakru/online_music/lx_js/lx_js_polyfill.dart';

export 'package:sylvakru/online_music/lx_js/lx_js_crypto.dart'
    show LxJsException;

/// 宿主允许的 action（preload.js 的 supportActions）。本次只实现 musicUrl。
const List<String> lxSupportedActions = ['musicUrl', 'lyric', 'pic'];

/// 已知音质。未知音源声明的音质若一个都不认识，就原样保留（宿主更严，这里放宽）。
const List<String> lxKnownQualitys = [
  '128k',
  '192k',
  '320k',
  'flac',
  'flac24bit',
  'ape',
  'wav',
  'master',
];

/// 脚本元信息，对应 `lx.currentScriptInfo`。
class LxScriptMeta {
  const LxScriptMeta({
    this.name = 'custom',
    this.description = '',
    this.version = '1.0',
    this.author = '',
    this.homepage = '',
  });

  final String name;
  final String description;
  final String version;
  final String author;
  final String homepage;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'version': version,
    'author': author,
    'homepage': homepage,
  };
}

/// 脚本 `lx.send('inited')` 声明的一个音源。
class LxSourceInfo {
  const LxSourceInfo({
    required this.source,
    required this.actions,
    required this.qualitys,
  });

  final String source;
  final List<String> actions;
  final List<String> qualitys;

  bool get hasMusicUrl => actions.contains('musicUrl');
}

/// 一个脚本对应一个 QuickJS 运行时。
class LxJsEngine {
  LxJsEngine._(this._runtime, this._dio, this._allowedHosts);

  static const Duration _initTimeout = Duration(seconds: 30);
  static const Duration _requestTimeout = Duration(seconds: 20);
  static const Duration _maxHttpTimeout = Duration(seconds: 60);

  final JavascriptRuntime _runtime;
  final Dio _dio;
  final Set<String>? _allowedHosts;

  final Completer<void> _inited = Completer<void>();
  final Map<String, Completer<Object?>> _requests = {};
  final Map<String, Timer> _timers = {};
  final Map<Object?, CancelToken> _tokens = {};

  Timer? _pump;
  bool _disposed = false;
  bool _hasRequestHandler = false;
  String? _initError;
  Map<String, LxSourceInfo> _sources = const {};

  Map<String, LxSourceInfo> get sources => _sources;

  /// 注入运行时 + 执行脚本，等到脚本 `lx.send('inited', ...)` 为止。
  static Future<LxJsEngine> load({
    required String script,
    LxScriptMeta meta = const LxScriptMeta(),
    Dio? dio,
    Set<String>? allowedHosts,
    Duration initTimeout = _initTimeout,
  }) async {
    // QuickJS 能捕获未处理的 promise rejection：脚本初始化阶段的失败
    // （比如拉 init.conf 失败）只有这条路能拿到原因。
    LxJsEngine? pending;
    final runtime = _createRuntime(
      (reason) => pending?._onUnhandledRejection(reason),
    );
    final engine = LxJsEngine._(runtime, dio ?? Dio(), allowedHosts);
    pending = engine;
    runtime.onMessage('lx_bridge', engine._onMessage);

    final injected = runtime.evaluate(lxJsPolyfill);
    if (injected.isError) {
      throw LxJsException('注入 lx 运行时失败: ${injected.stringResult}');
    }
    runtime.evaluate("__lx_setScriptInfo('${engine._b64(meta.toJson())}')");
    engine._startPump();

    final evaluated = runtime.evaluate(script);
    if (evaluated.isError) {
      engine._stop();
      throw LxJsException('脚本执行失败: ${evaluated.stringResult}');
    }
    // 脚本顶层 Promise 的失败（例如 juhe 拉 init.conf 失败）没有别的出口，
    // 记下来，等初始化超时时把原因带出去。
    final topLevel = evaluated.rawResult;
    if (topLevel is Future) {
      unawaited(
        topLevel.catchError((Object error) {
          engine._initError = error is JSError ? error.message : '$error';
        }),
      );
    }

    try {
      await engine._inited.future.timeout(initTimeout);
    } on TimeoutException {
      engine._stop();
      throw LxJsException(engine._initError ?? '脚本初始化超时');
    } catch (e) {
      engine._stop();
      rethrow;
    }
    return engine;
  }

  /// 取播放直链。`musicInfo` 用 lx 的旧格式歌曲对象（[见 OnlineTrack.toMusicInfo]）。
  Future<String> getMusicUrl({
    required String source,
    required Map<String, dynamic> musicInfo,
    required String quality,
  }) async {
    if (_disposed) throw LxJsException('脚本已关闭');
    if (!_hasRequestHandler) throw LxJsException('脚本没有注册 request 事件');

    final requestKey = _randomKey();
    final completer = Completer<Object?>();
    _requests[requestKey] = completer;
    _timers[requestKey] = Timer(_requestTimeout, () => _cancelRequest(requestKey));
    _startPump();

    final dispatched = _runtime.evaluate("__lx_dispatch('${_b64({
      'requestKey': requestKey,
      'data': {
        'source': source,
        'action': 'musicUrl',
        'info': {
          'type': quality,
          'musicInfo': musicInfo,
        },
      },
    })}')");
    if (dispatched.isError) {
      _cancelRequest(requestKey);
      throw LxJsException('脚本调用失败: ${dispatched.stringResult}');
    }

    final result = await completer.future;
    return _checkMusicUrl(result);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final key in _requests.keys.toList()) {
      _cancelRequest(key, reason: '脚本已关闭');
    }
    _stop();
  }

  // -------------------------------------------------------------------------
  // JS -> Dart
  // -------------------------------------------------------------------------

  Object? _onMessage(dynamic args) {
    final message = args is Map ? args : const <Object?, Object?>{};
    switch ('${message['t']}') {
      case 'send':
        return _onSend(message);
      case 'on':
        return _onSubscribe(message);
      case 'resp':
        _onResponse(message);
      case 'http':
        unawaited(_doHttp(message));
      case 'abort':
        _tokens.remove(message['id'])?.cancel();
      case 'util':
        return callLxJsUtil(
          '${message['fn']}',
          (message['args'] as List?) ?? const <Object?>[],
        );
      case 'log':
        lxJsLog('${message['msg']}');
      default:
        break;
    }
    return null;
  }

  Object? _onSend(Map<Object?, Object?> message) {
    switch ('${message['name']}') {
      case 'inited':
        final sources = _parseSources(message['data']);
        if (sources.isEmpty) {
          _failInit('脚本没有声明任何支持 musicUrl 的音源');
          return const {'ok': false, 'error': 'no usable source'};
        }
        _sources = sources;
        if (!_inited.isCompleted) _inited.complete();
        return const {'ok': true};
      case 'updateAlert':
        // 对应宿主的 showUpdateAlert：这里没有 UI，记一行日志即可。
        final data = message['data'];
        lxJsLog('脚本发布更新提示: ${data is Map ? data['log'] : data}');
        return const {'ok': true};
      default:
        return {'ok': false, 'error': 'The event is not supported: ${message['name']}'};
    }
  }

  Object? _onSubscribe(Map<Object?, Object?> message) {
    if ('${message['name']}' != 'request') {
      return {'ok': false, 'error': 'The event is not supported: ${message['name']}'};
    }
    _hasRequestHandler = true;
    return const {'ok': true};
  }

  void _onResponse(Map<Object?, Object?> message) {
    final requestKey = '${message['requestKey']}';
    final completer = _requests.remove(requestKey);
    _timers.remove(requestKey)?.cancel();
    _maybeStopPump();
    if (completer == null || completer.isCompleted) return;
    if (message['error'] != null) {
      completer.completeError(LxJsException('${message['error']}'));
    } else {
      completer.complete(message['result']);
    }
  }

  /// preload.js 的 handleInit：只留 type=music 且带 musicUrl 的音源。
  Map<String, LxSourceInfo> _parseSources(Object? data) {
    final declared = (data is Map ? data['sources'] : null) as Map?;
    if (declared == null) return const {};
    final result = <String, LxSourceInfo>{};
    for (final entry in declared.entries) {
      final info = entry.value as Map?;
      if (info == null || '${info['type']}' != 'music') continue;
      final actions =
          ((info['actions'] as List?) ?? const [])
              .map((e) => '$e')
              .where(lxSupportedActions.contains)
              .toList();
      if (!actions.contains('musicUrl')) continue;

      var qualitys =
          ((info['qualitys'] as List?) ?? const [])
              .map((e) => '$e')
              .where(lxKnownQualitys.contains)
              .toList();
      if (qualitys.isEmpty) {
        qualitys = ((info['qualitys'] as List?) ?? const []).map((e) => '$e').toList();
      }
      result['${entry.key}'] = LxSourceInfo(
        source: '${entry.key}',
        actions: actions,
        qualitys: qualitys,
      );
    }
    return result;
  }

  /// preload.js 的 handleRequest：musicUrl 必须是 http(s) 且不超过 2048。
  static String _checkMusicUrl(Object? value) {
    if (value is! String) throw LxJsException('脚本没有返回播放直链');
    if (value.length > 2048) throw LxJsException('播放直链过长');
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      throw LxJsException('播放直链不是 http(s) 地址');
    }
    return value;
  }

  void _failInit(String message) {
    if (!_inited.isCompleted) _inited.completeError(LxJsException(message));
  }

  void _cancelRequest(String requestKey, {String reason = 'Cancel request'}) {
    final completer = _requests.remove(requestKey);
    _timers.remove(requestKey)?.cancel();
    _maybeStopPump();
    if (completer != null && !completer.isCompleted) {
      completer.completeError(LxJsException(reason));
    }
  }

  // -------------------------------------------------------------------------
  // lx.request：Dio
  // -------------------------------------------------------------------------

  Future<void> _doHttp(Map<Object?, Object?> message) async {
    final id = message['id'];
    final token = CancelToken();
    _tokens[id] = token;
    try {
      final url = '${message['url']}';
      final uri = Uri.parse(url);
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw LxJsException('只允许 http(s) 请求: $url');
      }
      final allowedHosts = _allowedHosts;
      if (allowedHosts != null && !allowedHosts.contains(uri.host)) {
        throw LxJsException('请求主机不在白名单内: ${uri.host}');
      }

      final timeout = _httpTimeout(message['timeout']);
      final headers = (message['headers'] as Map?)?.map(
        (key, value) => MapEntry('$key', '$value'),
      );
      final contentType = _takeContentType(headers);
      final data = _requestData(
        message['body'] ?? message['form'] ?? message['formData'],
        isForm: message['body'] == null && message['form'] != null,
        isFormData:
            message['body'] == null &&
            message['form'] == null &&
            message['formData'] != null,
      );

      final response = await _dio.request<List<int>>(
        uri.toString(),
        data: data,
        cancelToken: token,
        options: Options(
          method: ('${message['method']}').toUpperCase(),
          headers: headers,
          contentType: contentType,
          responseType: ResponseType.bytes,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          connectTimeout: timeout,
          // needle 不因状态码抛错，状态码交给脚本自己判断。
          validateStatus: (status) => status != null,
        ),
      );
      _httpDone(id, response: response);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        _httpDone(id, error: 'Request aborted');
      } else {
        _httpDone(id, error: e.message ?? '网络请求失败');
      }
    } catch (e) {
      _httpDone(id, error: e is LxJsException ? e.message : '$e');
    } finally {
      _tokens.remove(id);
      _maybeStopPump();
    }
  }

  /// 仿 needle 的响应对象：{statusCode, statusMessage, headers, bytes, raw, body}。
  /// `raw` 走 base64（JS 侧还原成 Buffer），`body` 能 JSON 就 JSON。
  void _httpDone(Object? id, {Response<List<int>>? response, String? error}) {
    final payload = <String, Object?>{'id': id};
    if (error != null) {
      payload['err'] = error;
    } else {
      final bytes = Uint8List.fromList(response?.data ?? const <int>[]);
      final raw = _decodeBytes(bytes);
      payload['resp'] = {
        'statusCode': response?.statusCode ?? 0,
        'statusMessage': response?.statusMessage ?? '',
        'headers': (response?.headers.map ?? const {}).map(
          (key, value) => MapEntry(key, value.join(', ')),
        ),
        'bytes': bytes.length,
        'rawB64': base64Encode(bytes),
        'body': _tryDecodeJson(raw),
      };
    }
    if (_disposed) return;
    _runtime.evaluate("__lx_httpDone('${_b64(payload)}')");
  }

  Duration _httpTimeout(Object? value) {
    final ms = value is num ? value.toInt() : int.tryParse('$value');
    if (ms == null || ms <= 0) return _maxHttpTimeout;
    return Duration(
      milliseconds: min(ms, _maxHttpTimeout.inMilliseconds),
    );
  }

  /// 取走 headers 里的 Content-Type，交给 Options.contentType，避免被 Dio 覆盖。
  static String? _takeContentType(Map<String, String>? headers) {
    if (headers == null) return null;
    final key = headers.keys.firstWhere(
      (k) => k.toLowerCase() == 'content-type',
      orElse: () => '',
    );
    if (key.isEmpty) return null;
    return headers.remove(key);
  }

  static Object? _requestData(
    Object? value, {
    required bool isForm,
    required bool isFormData,
  }) {
    if (value is Map) {
      final encoded = value['__lx_b'];
      if (encoded is String) return base64Decode(encoded);
      if (isFormData) return FormData.fromMap(Map<String, dynamic>.from(value));
      return isForm ? value : Map<String, dynamic>.from(value);
    }
    return value;
  }

  static Object? _tryDecodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return body;
    }
  }

  /// 与仓库其它地方一致：先 utf8，失败退 gbk。
  static String _decodeBytes(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  // -------------------------------------------------------------------------
  // 事件循环 / 生命周期
  // -------------------------------------------------------------------------

  /// 桌面/安卓走 QuickJS（带 rejection 钩子）；苹果平台只能走 JavaScriptCore。
  static JavascriptRuntime _createRuntime(void Function(dynamic reason) onRejection) {
    if (Platform.isWindows || Platform.isLinux || Platform.isAndroid) {
      return QuickJsRuntime2(hostPromiseRejectionHandler: onRejection);
    }
    return getJavascriptRuntime(xhr: false);
  }

  void _onUnhandledRejection(dynamic reason) {
    final raw = reason is JSError ? reason.message : '$reason';
    _failInit('脚本初始化失败: ${raw.replaceFirst(RegExp(r'^Error:\s*'), '')}');
  }

  /// QuickJS 的 promise 续体要靠手动跑 pending job，脚本和请求都可能依赖它。
  void _startPump() {
    if (_disposed || _pump != null) return;
    _pump = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_disposed) return;
      try {
        _runtime.executePendingJob();
      } catch (_) {
        // ponytail: 引擎已释放时会抛，忽略即可。
      }
    });
  }

  void _maybeStopPump() {
    if (_disposed ||
        !_inited.isCompleted ||
        _requests.isNotEmpty ||
        _tokens.isNotEmpty) {
      return;
    }
    _pump?.cancel();
    _pump = null;
  }

  void _stop() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final token in _tokens.values) {
      token.cancel();
    }
    _tokens.clear();
    _pump?.cancel();
    _pump = null;
    _runtime.dispose();
    _dio.close();
  }

  String _b64(Object? payload) => base64Encode(utf8.encode(jsonEncode(payload)));

  static String _randomKey() {
    final random = Random();
    return 'request__${DateTime.now().microsecondsSinceEpoch}${random.nextInt(1 << 30)}';
  }

}

/// 记一行日志。logger 未 init 时（单测直接跑引擎的场景）静默跳过。
void lxJsLog(String message) {
  try {
    logger.output('[lx-js] $message');
  } catch (_) {
    // ignore
  }
}
