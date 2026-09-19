// 在线音乐：搜索器 + 本地设置 + 播放直链解析。
//
// 直链解析不再复刻某个具体接口，而是直接跑 lx-music 的「自定义源」脚本：
// Dart 复刻宿主注入的 `window.lx`，用 QuickJS 原样执行用户 JS（见 lx_js/）。
// 脚本怎么取链是脚本自己的事（聚合接口、303 二次校验……），这里只做三件事：
//   1. 等脚本 `lx.send('inited')`，拿到它声明的音源与音质
//   2. 把歌曲对象（lx 旧格式）交给脚本的 request 事件
//   3. 校验脚本返回的直链是 http(s) 且长度合规
//
// 自定义源脚本只注册 request 事件、**不提供搜索**，所以搜索仍由本文件的两个
// Searcher 按 lx-music 内置实现的接口与解析规则自己实现。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sylvakru/base/app.dart';
import 'package:sylvakru/base/services/logger.dart';
import 'package:sylvakru/online_music/lx_js/lx_js_bridge.dart';
import 'package:sylvakru/online_music/lx_js/lx_js_source.dart';

/// 接口地址默认留空：必须由用户在「接口设置」里手动填写自己的洛雪音乐接口，
/// 不再内置任何默认地址。

/// lx-music 对**所有**请求都带这个 UA，酷我/咪咕的接口都依赖它。
const String _lxUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/69.0.3497.100 Safari/537.36';

const String _mgUserAgent =
    'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) '
    'AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30';

/// 与 lx-music 的默认请求超时保持一致。聚合接口走 Cloudflare，
/// 10s 实测偶发超时，15s 更稳。
const Duration _requestTimeout = Duration(seconds: 15);

/// 音质由低到高的惯例顺序，用于给 UI 排序与挑选默认值。
const List<String> qualityOrder = ['128k', '320k', 'flac', 'flac24bit', 'master'];

// ---------------------------------------------------------------------------
// 通用小工具
// ---------------------------------------------------------------------------

class OnlineApiException implements Exception {
  OnlineApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, dynamic> _asMap(Object? value) => value is Map
    ? value.map((key, value) => MapEntry('$key', value))
    : const <String, dynamic>{};

Map<String, dynamic> _asJsonObject(String body, String what) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw OnlineApiException('$what 返回的不是合法 JSON（${e.message}）');
  }
  if (decoded is! Map) throw OnlineApiException('$what 返回的不是 JSON 对象');
  return decoded.map((key, value) => MapEntry('$key', value));
}

/// http 包的 `Response.body` 在响应没声明 charset 时按 latin1 解，中文会乱码。
/// 先按 utf8 严格解，失败再退 gbk —— 国内这几个老接口不是 utf8 就是 gbk。
String _decodeBody(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return gbk.decode(bytes, allowMalformed: true);
  }
}

Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) async {
  try {
    final response = await http
        .get(uri, headers: {'User-Agent': _lxUserAgent, ...?headers})
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw OnlineApiException('HTTP ${response.statusCode}');
    }
    return response;
  } on TimeoutException {
    throw OnlineApiException('请求超时');
  } on SocketException catch (e) {
    throw OnlineApiException('网络不可达：${e.osError?.message ?? '连接失败'}');
  } on http.ClientException catch (e) {
    throw OnlineApiException('网络异常：${e.message}');
  }
}

/// HTML 实体解码。酷我返回的歌名里带 `&nbsp;` 之类的实体。
/// ponytail: 只处理常见实体，够用；真遇到冷门实体再加表。
String decodeName(String value) {
  if (value.isEmpty) return '';
  return value
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (match) => String.fromCharCode(int.parse(match.group(1)!)),
      );
}

String _formatPlayTime(int? seconds) {
  if (seconds == null || seconds <= 0) return '00:00';
  final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return '$minutes:$rest';
}

String _sizeFormat(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)}M';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
  return '${bytes}B';
}

// ---------------------------------------------------------------------------
// 搜索结果
// ---------------------------------------------------------------------------

/// 一条在线搜索结果。
///
/// 字段刻意保持 lx-music 的「旧格式 musicInfo」形状，[toMusicInfo] 才能原样
/// POST 给聚合接口 —— 服务端解析的就是这套字段。
class OnlineTrack {
  OnlineTrack({
    required this.source,
    required this.songmid,
    required this.name,
    required this.singer,
    required this.albumName,
    required this.albumId,
    required this.interval,
    required this.types,
    this.img,
    this.extra = const {},
  });

  final String source; // 'kw' | 'mg'
  final String songmid;
  final String name;
  final String singer;
  final String albumName;
  final String albumId;
  final String interval; // '04:29'
  final String? img;

  /// `[{type: '320k', size: '8.1M'}]`
  final List<Map<String, String>> types;

  /// 源特有字段（mg 的 copyrightId / lrcUrl / mrcUrl / trcUrl）。
  final Map<String, dynamic> extra;

  /// 加 `online_` 前缀，避免和本地曲目 id 撞车。
  String get id => 'online_${source}_$songmid';

  List<String> get qualitys => types
      .map((type) => type['type'] ?? '')
      .where((type) => type.isNotEmpty)
      .toList();

  Map<String, dynamic> toMusicInfo() => {
    'name': name,
    'singer': singer,
    'source': source,
    'songmid': songmid,
    'interval': interval,
    'albumName': albumName,
    'img': img ?? '',
    'typeUrl': <String, dynamic>{},
    'albumId': albumId,
    'types': types,
    '_types': {
      for (final type in types)
        type['type']!: {'size': type['size'] ?? ''},
    },
    ...extra,
  };
}

/// 一条在线歌单搜索结果。
class OnlinePlaylist {
  OnlinePlaylist({
    required this.source,
    required this.id,
    required this.name,
    required this.creator,
    required this.pic,
    required this.songCount,
    required this.playCount,
    this.intro,
  });

  final String source; // 'kw' | 'mg'
  final String id;
  final String name;
  final String creator;
  final String pic;
  final int songCount;
  final int playCount;
  final String? intro;

  String get songCountFormatted => '$songCount 首';

  String get playCountFormatted {
    if (playCount >= 100000000) {
      return '${(playCount / 100000000).toStringAsFixed(1)}亿播放';
    }
    if (playCount >= 10000) {
      return '${(playCount / 10000).toStringAsFixed(1)}万播放';
    }
    if (playCount > 0) return '$playCount 播放';
    return '';
  }
}

// ---------------------------------------------------------------------------
// 本地设置
// ---------------------------------------------------------------------------

/// 在线音乐的本地设置：自定义源脚本、默认音质、下载目录。
class OnlineSettings {
  static const String _fileName = 'online_music_settings.json';

  /// 脚本正文单独存文件：脚本动辄几十 KB，塞进设置 JSON 不好读也不好改。
  static const String _scriptFileName = 'online_music_script.js';

  final ValueNotifier<String> scriptName = ValueNotifier('');
  final ValueNotifier<String> quality = ValueNotifier('128k');

  /// 下载目录。存 URI 字符串：桌面是 `file://`，Android 是 `content://`，
  /// iOS 是 `urlbookmark://`（只有 URI 才能跨重启恢复访问权限）。
  final ValueNotifier<String> downloadDir = ValueNotifier('');

  File get _file => File('${appSupportDir.path}/$_fileName');

  File get _scriptFile => File('${appSupportDir.path}/$_scriptFileName');

  bool get hasScript => scriptName.value.isNotEmpty && _scriptFile.existsSync();

  /// 已导入的脚本正文；没导入过就是空串。
  String get script {
    if (!hasScript) return '';
    try {
      return _scriptFile.readAsStringSync();
    } catch (e) {
      logger.output('[online] 脚本读取失败: $e');
      return '';
    }
  }

  /// 导入脚本：写入脚本文件并记住名字。
  Future<void> importScript(String source, String name) async {
    await _scriptFile.writeAsString(source);
    scriptName.value = name;
    await save();
  }

  Future<void> removeScript() async {
    if (_scriptFile.existsSync()) {
      await _scriptFile.delete();
    }
    scriptName.value = '';
    await save();
  }

  Future<void> load() async {
    try {
      final file = _file;
      if (!file.existsSync()) return;
      final map = _asMap(jsonDecode(await file.readAsString()));
      scriptName.value = map['scriptName'] as String? ?? '';
      quality.value = map['quality'] as String? ?? '128k';
      downloadDir.value = map['downloadDir'] as String? ?? '';
    } catch (e) {
      logger.output('[online] 设置读取失败: $e');
    }
  }

  Future<void> save() async {
    try {
      await _file.writeAsString(
        jsonEncode({
          'scriptName': scriptName.value,
          'quality': quality.value,
          'downloadDir': downloadDir.value,
        }),
      );
    } catch (e) {
      logger.output('[online] 设置写入失败: $e');
    }
  }
}

final OnlineSettings onlineSettings = OnlineSettings();

// ---------------------------------------------------------------------------
// 搜索器
// ---------------------------------------------------------------------------

abstract class OnlineSearcher {
  String get source;

  String get label;

  int get pageSize;

  Future<List<OnlineTrack>> search(String keyword, {int page});

  Future<List<OnlinePlaylist>> searchPlaylists(String keyword, {int page});

  Future<List<OnlineTrack>> getPlaylistTracks(
    String playlistId, {
    int page,
    int pageSize,
  });
}

final Map<String, OnlineSearcher> onlineSearchers = {
  'kw': KwSearcher(),
  'mg': MgSearcher(),
};

/// 酷我。接口与解析规则取自 lx-music 的 `musicSdk/kw/musicSearch.js`。
class KwSearcher implements OnlineSearcher {
  @override
  String get source => 'kw';

  @override
  String get label => '酷我';

  @override
  int get pageSize => 30;

  static final RegExp _qualityPattern = RegExp(
    r'level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)',
  );

  @override
  Future<List<OnlineTrack>> search(String keyword, {int page = 1}) async {
    final query =
        'client=kt'
        '&all=${Uri.encodeComponent(keyword)}'
        '&pn=${page - 1}'
        '&rn=$pageSize'
        '&uid=794762570'
        '&ver=kwplayer_ar_9.2.2.1'
        '&vipver=1'
        '&show_copyright_off=1'
        '&newver=1'
        '&ft=music'
        '&cluster=0'
        '&strategy=2012'
        '&encoding=utf8'
        '&rformat=json'
        '&vermerge=1'
        '&mobi=1'
        '&issubtitle=1';
    final response = await _get(Uri.parse('https://search.kuwo.cn/r.s?$query'));
    final json = _asJsonObject(_decodeBody(response.bodyBytes), '酷我搜索');
    return parseAbslist(json['abslist']);
  }

  /// 解析酷我搜索响应的 `abslist`。
  List<OnlineTrack> parseAbslist(Object? abslist) {
    final result = <OnlineTrack>[];
    for (final item in (abslist as List?) ?? const []) {
      final info = _asMap(item);
      final musicRid = '${info['MUSICRID'] ?? ''}';
      final nMinfo = info['N_MINFO'];
      // 没有 N_MINFO 的条目不可播（搜索结果里会混着非歌曲项）。
      if (musicRid.isEmpty || nMinfo is! String || nMinfo.isEmpty) continue;
      final types = _parseQualitys(nMinfo);
      if (types.isEmpty) continue;
      result.add(
        OnlineTrack(
          source: source,
          songmid: musicRid.replaceFirst('MUSIC_', ''),
          name: decodeName('${info['SONGNAME'] ?? ''}'),
          singer: decodeName('${info['ARTIST'] ?? ''}'),
          albumName: decodeName('${info['ALBUM'] ?? ''}'),
          albumId: decodeName('${info['ALBUMID'] ?? ''}'),
          interval: _formatPlayTime(int.tryParse('${info['DURATION']}')),
          types: types,
        ),
      );
    }
    return result;
  }

  /// `N_MINFO` 是 `level:x,bitrate:n,format:y,size:z` 的分号列表，
  /// bitrate 4000/2000/320/128 分别对应 flac24bit/flac/320k/128k。
  static List<Map<String, String>> _parseQualitys(String nMinfo) {
    final byType = <String, Map<String, String>>{};
    for (final chunk in nMinfo.split(';')) {
      final match = _qualityPattern.firstMatch(chunk);
      if (match == null) continue;
      final type = switch (match.group(2)) {
        '4000' => 'flac24bit',
        '2000' => 'flac',
        '320' => '320k',
        '128' => '128k',
        _ => null,
      };
      if (type == null) continue;
      byType[type] = {'type': type, 'size': (match.group(4) ?? '').toUpperCase()};
    }
    return qualityOrder.where(byType.containsKey).map((t) => byType[t]!).toList();
  }

  @override
  Future<List<OnlinePlaylist>> searchPlaylists(String keyword, {int page = 1}) async {
    final query =
        'client=kt'
        '&all=${Uri.encodeComponent(keyword)}'
        '&pn=${page - 1}'
        '&rn=$pageSize'
        '&uid=794762570'
        '&ver=kwplayer_ar_9.2.2.1'
        '&vipver=1'
        '&show_copyright_off=1'
        '&newver=1'
        '&ft=playlist'
        '&cluster=0'
        '&strategy=2012'
        '&encoding=utf8'
        '&rformat=json'
        '&vermerge=1'
        '&mobi=1';
    final response = await _get(Uri.parse('https://search.kuwo.cn/r.s?$query'));
    final json = _asJsonObject(_decodeBody(response.bodyBytes), '酷我歌单搜索');
    return parsePlaylistAbslist(json['abslist']);
  }

  List<OnlinePlaylist> parsePlaylistAbslist(Object? abslist) {
    final result = <OnlinePlaylist>[];
    for (final item in (abslist as List?) ?? const []) {
      final info = _asMap(item);
      final id = '${info['playlistid'] ?? info['DC_TARGETID'] ?? ''}';
      if (id.isEmpty) continue;
      final pic = '${info['pic'] ?? info['hts_pic'] ?? ''}';
      result.add(
        OnlinePlaylist(
          source: source,
          id: id,
          name: decodeName('${info['name'] ?? ''}'),
          creator: decodeName('${info['nickname'] ?? ''}'),
          pic: pic,
          songCount: int.tryParse('${info['songnum'] ?? 0}') ?? 0,
          playCount: int.tryParse('${info['playcnt'] ?? 0}') ?? 0,
          intro: decodeName('${info['intro'] ?? ''}'),
        ),
      );
    }
    return result;
  }

  @override
  Future<List<OnlineTrack>> getPlaylistTracks(
    String playlistId, {
    int page = 1,
    int pageSize = 50,
  }) async {
    final response = await _get(
      Uri.parse(
        'https://m.kuwo.cn/newh5app/wapi/api/www/playlist/playListInfo'
        '?pid=$playlistId&pn=$page&rn=$pageSize',
      ),
    );
    final json = _asJsonObject(_decodeBody(response.bodyBytes), '酷我歌单详情');
    final data = _asMap(json['data']);
    final musicList = (data['musicList'] as List?) ?? const [];
    final result = <OnlineTrack>[];
    for (final item in musicList) {
      final info = _asMap(item);
      final musicrid = '${info['musicrid'] ?? ''}';
      final songmid = musicrid.isNotEmpty
          ? musicrid.replaceFirst('MUSIC_', '')
          : '${info['rid'] ?? ''}';
      if (songmid.isEmpty) continue;
      final duration = int.tryParse('${info['duration'] ?? 0}') ?? 0;
      var pic = '${info['pic'] ?? info['albumpic'] ?? ''}';

      result.add(
        OnlineTrack(
          source: source,
          songmid: songmid,
          name: decodeName('${info['name'] ?? ''}'),
          singer: decodeName('${info['artist'] ?? ''}'),
          albumName: decodeName('${info['album'] ?? ''}'),
          albumId: '${info['albumid'] ?? ''}',
          interval: _formatPlayTime(duration),
          img: pic.isEmpty ? null : pic,
          types: const [
            {'type': '128k', 'size': ''},
            {'type': '320k', 'size': ''},
            {'type': 'flac', 'size': ''},
          ],
        ),
      );
    }
    return result;
  }
}

/// 咪咕。接口、签名与解析规则取自 lx-music 的 `musicSdk/mg/musicSearch.js`。
class MgSearcher implements OnlineSearcher {
  @override
  String get source => 'mg';

  @override
  String get label => '咪咕';

  @override
  int get pageSize => 20;

  static const String deviceId = '963B7AA0D21511ED807EE5846EC87D20';
  static const String _signatureMd5 =
      '6cdc72a439cef99a3418d2a78aa28c73';
  static const String _signatureTail = 'yyapp2d16148780a1dcc7408e06336b98cfd50';

  /// 服务端要求的签名：`md5(关键词 + 常量 + 常量 + deviceId + 毫秒时间戳)`。
  static String buildSign(String keyword, String timestamp) => md5
      .convert(
        utf8.encode(
          '$keyword$_signatureMd5$_signatureTail$deviceId$timestamp',
        ),
      )
      .toString();

  @override
  Future<List<OnlineTrack>> search(String keyword, {int page = 1}) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final query =
        'isCorrect=0'
        '&isCopyright=1'
        '&searchSwitch=%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0'
        '%2C%22tagSong%22%3A1%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1'
        '%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D'
        '&pageSize=$pageSize'
        '&text=${Uri.encodeComponent(keyword)}'
        '&pageNo=$page'
        '&sort=0'
        '&sid=USS';
    final response = await _get(
      Uri.parse('https://jadeite.migu.cn/music_search/v3/search/searchAll?$query'),
      headers: {
        'uiVersion': 'A_music_3.6.1',
        'deviceId': deviceId,
        'timestamp': timestamp,
        'sign': buildSign(keyword, timestamp),
        'channel': '0146921',
        'User-Agent': _mgUserAgent,
      },
    );
    final json = _asJsonObject(_decodeBody(response.bodyBytes), '咪咕搜索');
    if (json['code'] != '000000') {
      throw OnlineApiException('咪咕搜索失败（code=${json['code']}）');
    }

    return parseResultList(_asMap(json['songResultData'])['resultList']);
  }

  /// 解析咪咕搜索响应的 `songResultData.resultList`（二维数组）。
  List<OnlineTrack> parseResultList(Object? resultList) {
    final result = <OnlineTrack>[];
    final seen = <String>{};
    for (final group in (resultList as List?) ?? const []) {
      if (group is! List) continue;
      for (final item in group) {
        final data = _asMap(item);
        final copyrightId = '${data['copyrightId'] ?? ''}';
        final songId = '${data['songId'] ?? ''}';
        if (copyrightId.isEmpty ||
            songId.isEmpty ||
            !seen.add(copyrightId)) {
          continue;
        }
        final types = _parseQualitys(data['audioFormats']);
        if (types.isEmpty) continue;

        var img = '${data['img3'] ?? data['img2'] ?? data['img1'] ?? ''}';
        if (img.isNotEmpty && !img.startsWith('http')) {
          img = 'http://d.musicapp.migu.cn$img';
        }

        result.add(
          OnlineTrack(
            source: source,
            songmid: songId,
            name: decodeName('${data['name'] ?? ''}'),
            singer: _formatSingerName(data['singerList']),
            albumName: decodeName('${data['album'] ?? ''}'),
            albumId: '${data['albumId'] ?? ''}',
            interval: _formatPlayTime(int.tryParse('${data['duration']}')),
            img: img.isEmpty ? null : img,
            types: types,
            extra: {
              'copyrightId': copyrightId,
              if (data['lrcUrl'] != null) 'lrcUrl': data['lrcUrl'],
              if (data['mrcurl'] != null) 'mrcUrl': data['mrcurl'],
              if (data['trcUrl'] != null) 'trcUrl': data['trcUrl'],
            },
          ),
        );
      }
    }
    return result;
  }

  static List<Map<String, String>> _parseQualitys(Object? formats) {
    final byType = <String, Map<String, String>>{};
    for (final raw in (formats as List?) ?? const []) {
      final item = _asMap(raw);
      final type = switch ('${item['formatType']}') {
        'PQ' => '128k',
        'HQ' => '320k',
        'SQ' => 'flac',
        'ZQ24' => 'flac24bit',
        _ => null,
      };
      if (type == null) continue;
      byType[type] = {
        'type': type,
        'size': _sizeFormat(int.tryParse('${item['asize'] ?? item['isize']}')),
      };
    }
    return qualityOrder.where(byType.containsKey).map((t) => byType[t]!).toList();
  }

  static String _formatSingerName(Object? singers) {
    if (singers is List) {
      return decodeName(
        singers
            .map((singer) => '${_asMap(singer)['name'] ?? ''}')
            .where((name) => name.isNotEmpty)
            .join('、'),
      );
    }
    return decodeName('${singers ?? ''}');
  }

  @override
  Future<List<OnlinePlaylist>> searchPlaylists(String keyword, {int page = 1}) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final query =
        'isCorrect=0'
        '&isCopyright=1'
        '&searchSwitch=%7B%22song%22%3A0%2C%22album%22%3A0%2C%22singer%22%3A0'
        '%2C%22tagSong%22%3A0%2C%22mvSong%22%3A0%2C%22bestShow%22%3A0'
        '%2C%22songlist%22%3A1%2C%22lyricSong%22%3A0%7D'
        '&pageSize=$pageSize'
        '&text=${Uri.encodeComponent(keyword)}'
        '&pageNo=$page'
        '&sort=0'
        '&sid=USS';
    final response = await _get(
      Uri.parse('https://jadeite.migu.cn/music_search/v3/search/searchAll?$query'),
      headers: {
        'uiVersion': 'A_music_3.6.1',
        'deviceId': deviceId,
        'timestamp': timestamp,
        'sign': buildSign(keyword, timestamp),
        'channel': '0146921',
        'User-Agent': _mgUserAgent,
      },
    );
    final json = _asJsonObject(_decodeBody(response.bodyBytes), '咪咕歌单搜索');
    if (json['code'] != '000000') {
      throw OnlineApiException('咪咕歌单搜索失败（code=${json['code']}）');
    }
    final sld = _asMap(json['songListResultData']);
    final list = (sld['result'] as List?) ?? const [];
    final result = <OnlinePlaylist>[];
    for (final item in list) {
      final data = _asMap(item);
      final id = '${data['id'] ?? data['musicListId'] ?? ''}';
      if (id.isEmpty) continue;
      var img = '${data['img'] ?? data['musicListPic'] ?? ''}';
      if (img.isNotEmpty && !img.startsWith('http')) {
        img = 'http://d.musicapp.migu.cn$img';
      }
      result.add(
        OnlinePlaylist(
          source: source,
          id: id,
          name: decodeName('${data['name'] ?? ''}'),
          creator: decodeName('${data['userName'] ?? ''}'),
          pic: img,
          songCount: int.tryParse('${data['musicNum'] ?? 0}') ?? 0,
          playCount: int.tryParse('${data['playNum'] ?? 0}') ?? 0,
          intro: decodeName('${data['summary'] ?? ''}'),
        ),
      );
    }
    return result;
  }

  @override
  Future<List<OnlineTrack>> getPlaylistTracks(
    String playlistId, {
    int page = 1,
    int pageSize = 50,
  }) async {
    final response = await _get(
      Uri.parse(
        'https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0'
        '?playlistId=$playlistId&pageNo=$page&pageSize=$pageSize',
      ),
      headers: {
        'User-Agent': _mgUserAgent,
      },
    );
    final json = _asJsonObject(_decodeBody(response.bodyBytes), '咪咕歌单详情');
    final data = _asMap(json['data']);
    final songList = (data['songList'] as List?) ?? const [];
    final result = <OnlineTrack>[];
    for (final item in songList) {
      final track = _asMap(item);
      final copyrightId = '${track['copyrightId'] ?? ''}';
      final songId = '${track['songId'] ?? ''}';
      if (copyrightId.isEmpty || songId.isEmpty) continue;
      final types = _parseQualitys(track['audioFormats']);
      if (types.isEmpty) continue;

      var img = '${track['img3'] ?? track['img2'] ?? track['img1'] ?? ''}';
      if (img.isNotEmpty && !img.startsWith('http')) {
        img = 'http://d.musicapp.migu.cn$img';
      }

      result.add(
        OnlineTrack(
          source: source,
          songmid: songId,
          name: decodeName('${track['songName'] ?? ''}'),
          singer: _formatSingerName(track['singerList']),
          albumName: decodeName('${track['album'] ?? ''}'),
          albumId: '${track['albumId'] ?? ''}',
          interval: _formatPlayTime(int.tryParse('${track['duration']}')),
          img: img.isEmpty ? null : img,
          types: types,
          extra: {
            'copyrightId': copyrightId,
            if (track['lrcUrl'] != null) 'lrcUrl': track['lrcUrl'],
            if (track['mrcurl'] != null) 'mrcUrl': track['mrcurl'],
            if (track['trcUrl'] != null) 'trcUrl': track['trcUrl'],
          },
        ),
      );
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// 直链解析：交给自定义源脚本
// ---------------------------------------------------------------------------

class OnlineApiClient {
  /// `source|songmid|quality` -> 直链。
  /// ponytail: 只放内存、上限 200 条；重启失效可接受，真要跨进程复用再落盘。
  final Map<String, String> _urlCache = {};
  static const int _urlCacheLimit = 200;

  /// 脚本声明的音源 -> 可用音质。已经跑起来就直接返回缓存。
  Future<Map<String, List<String>>> fetchSources() async {
    final sources = await _ensureLoaded();
    return sources.map((source, info) => MapEntry(source, info.qualitys));
  }

  Future<Map<String, LxSourceInfo>> _ensureLoaded() async {
    if (lxJsSources.isReady) return lxJsSources.sources;
    final script = onlineSettings.script;
    if (script.isEmpty) return const {};
    try {
      return await lxJsSources.load(
        script: script,
        meta: LxScriptMeta(name: onlineSettings.scriptName.value),
      );
    } on LxJsException catch (e) {
      throw OnlineApiException(e.message);
    }
  }

  /// 解析播放直链：把歌曲对象交给脚本的 request 事件。
  Future<String> resolveUrl({
    required OnlineTrack track,
    required String quality,
  }) async {
    final cacheKey = '${track.source}|${track.songmid}|$quality';
    final cached = _urlCache[cacheKey];
    if (cached != null) return cached;

    final sources = await _ensureLoaded();
    if (sources.isEmpty) {
      throw OnlineApiException('还没有导入自定义源脚本，请在「音源设置」里导入');
    }
    if (sources[track.source] == null) {
      throw OnlineApiException('自定义源脚本不支持音源 ${track.source}');
    }

    try {
      final url = await lxJsSources.getMusicUrl(
        track.source,
        track.toMusicInfo(),
        quality,
      );
      _cacheUrl(cacheKey, url);
      return url;
    } on LxJsException catch (e) {
      logger.output('[online] ${track.source} ${track.name} 解析失败: ${e.message}');
      throw OnlineApiException(e.message);
    }
  }

  /// 脚本变了就重新加载（导入新脚本后调用）。
  Future<void> reload() async {
    await lxJsSources.unload();
    _urlCache.clear();
  }

  void _cacheUrl(String key, String url) {
    _urlCache.remove(key);
    _urlCache[key] = url;
    while (_urlCache.length > _urlCacheLimit) {
      _urlCache.remove(_urlCache.keys.first);
    }
  }
}

final OnlineApiClient onlineApiClient = OnlineApiClient();
