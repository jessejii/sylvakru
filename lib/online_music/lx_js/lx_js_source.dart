// 自定义源脚本的生命周期管理：一个脚本 -> 一个 QuickJS 运行时。
//
// 上层（OnlineApiClient）只跟这里打交道，不直接碰引擎。

import 'package:sylvakru/online_music/lx_js/lx_js_bridge.dart';

class LxJsSourceManager {
  LxJsEngine? _engine;
  Map<String, LxSourceInfo> _sources = const {};

  /// 脚本 `lx.send('inited')` 声明的音源表。
  Map<String, LxSourceInfo> get sources => _sources;

  bool get isReady => _engine != null;

  /// 导入（或替换）脚本，等它 inited 后返回音源表。
  Future<Map<String, LxSourceInfo>> load({
    required String script,
    LxScriptMeta meta = const LxScriptMeta(),
    Set<String>? allowedHosts,
  }) async {
    await unload();
    final engine = await LxJsEngine.load(
      script: script,
      meta: meta,
      allowedHosts: allowedHosts,
    );
    _engine = engine;
    _sources = engine.sources;
    return _sources;
  }

  /// 取播放直链。`musicInfo` 是 lx 旧格式的歌曲对象。
  Future<String> getMusicUrl(
    String source,
    Map<String, dynamic> musicInfo,
    String quality,
  ) async {
    final engine = _engine;
    if (engine == null) throw LxJsException('还没有导入自定义源脚本');
    return engine.getMusicUrl(
      source: source,
      musicInfo: musicInfo,
      quality: quality,
    );
  }

  /// 歌曲自身音质 ∩ 脚本声明音质；脚本没声明就原样返回。
  List<String> qualitysOf(String source, List<String> own) {
    final declared = _sources[source]?.qualitys ?? const [];
    if (declared.isEmpty) return own;
    final result = own.where(declared.contains).toList();
    return result.isEmpty ? own : result;
  }

  Future<void> unload() async {
    final engine = _engine;
    _engine = null;
    _sources = const {};
    if (engine != null) await engine.dispose();
  }
}

final LxJsSourceManager lxJsSources = LxJsSourceManager();
