// 在线音乐的单曲下载。
//
// 目录：桌面用 file_picker 拿路径转 `file://`；移动端用插件自带的系统选择器
// （Android 是 `content://`，iOS 是 `urlbookmark://`）。统一存成 URI 字符串，
// 每次下载前过一遍 `uri.activate()` 恢复访问权限 —— 移动端沙盒路径会变，
// 只有 URI（或书签）能跨重启复用。
//
// 下载：先由 [onlineApiClient] 解析直链，再用 `UriDownloadTask` 直写目标目录
// （Android 上因此绕开了临时文件中转）。进度走 Transfer 的 notifier，UI 直接绑。

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:sylvakru/base/app.dart';
import 'package:sylvakru/base/services/logger.dart';
import 'package:sylvakru/online_music/online_music_api.dart';

enum OnlineDownloadState {
  /// 正在由自定义源脚本解析播放直链。
  resolving,
  enqueued,
  running,
  paused,
  complete,
  failed,
  canceled;

  bool get isActive => switch (this) {
    .resolving || .enqueued || .running || .paused => true,
    _ => false,
  };
}

/// 一条下载记录。只活在内存里：重启后列表清空，文件仍在目录里。
class OnlineDownloadEntry {
  OnlineDownloadEntry({
    required this.trackId,
    required this.quality,
    required this.fileName,
  });

  final String trackId;
  final String quality;
  final String fileName;

  OnlineDownloadState state = OnlineDownloadState.resolving;
  double progress = 0;
  String? error;
}

class OnlineDownloader {
  final ValueNotifier<List<OnlineDownloadEntry>> entries = ValueNotifier([]);

  /// trackId -> 进行中的 Transfer。已结束的保留到 [remove]/[clearFinished]。
  final Map<String, Transfer> _transfers = {};
  bool _started = false;
  bool _notificationAsked = false;

  bool get hasDirectory => onlineSettings.downloadDir.value.isNotEmpty;

  /// 设置项里展示用的目录文本。移动端拿不到真实路径，只说清是什么类型的位置。
  String get directoryDisplay {
    final raw = onlineSettings.downloadDir.value;
    final uri = raw.isEmpty ? null : Uri.tryParse(raw);
    return switch (uri) {
      null => '未设置',
      final u when u.scheme == 'file' => u.toFilePath(windows: Platform.isWindows),
      final u => '已选择目录（${u.scheme}）',
    };
  }

  Future<void> init() async {
    if (_started) return;
    _started = true;
    await FileDownloader().start(autoCleanDatabase: true);
    FileDownloader().configureNotification(
      running: const TaskNotification('正在下载', '{filename}'),
      complete: const TaskNotification('下载完成', '{filename}'),
      error: const TaskNotification('下载失败', '{filename}'),
      progressBar: true,
      tapOpensFile: true,
    );
  }

  /// 弹出系统目录选择器并记住结果。取消返回 null。
  Future<Uri?> pickDirectory() async {
    final uri = isMobile
        ? await FileDownloader().uri.pickDirectory(persistedUriPermission: true)
        : await _pickDesktopDirectory();
    if (uri == null) return null;
    onlineSettings.downloadDir.value = uri.toString();
    await onlineSettings.save();
    return uri;
  }

  static Future<Uri?> _pickDesktopDirectory() async {
    final path = await FilePicker.getDirectoryPath();
    return path == null ? null : Uri.file(path, windows: Platform.isWindows);
  }

  /// 下载一首歌。返回 null 表示已开始，否则是要给用户看的错误文案。
  Future<String?> download(OnlineTrack track, {String? quality}) async {
    final existing = entryOf(track.id);
    if (existing != null) {
      if (existing.state.isActive) return null; // 已经在下载，忽略重复点击
      remove(track.id); // 之前失败/取消过，重新来一次
    }

    final dir = await _directoryUri();
    if (dir == null) return '请先选择下载目录（设置 → 下载目录）';

    final q = quality ?? _defaultQuality(track);
    final entry = OnlineDownloadEntry(
      trackId: track.id,
      quality: q,
      fileName: _buildFileName(track, q, dir),
    );
    entries.value.add(entry);
    _notify();

    var url = '';
    try {
      url = await onlineApiClient.resolveUrl(track: track, quality: q);
    } catch (e) {
      final reason = e is OnlineApiException ? e.message : '$e';
      entry
        ..state = OnlineDownloadState.failed
        ..error = reason;
      _notify();
      return '「${track.name}」解析失败：$reason';
    }
    // 直链是 http 的统一升级成 https，避免明文下载。
    if (url.startsWith('http://')) url = url.replaceFirst('http://', 'https://');
    if (entryOf(track.id) != entry) return null; // 解析期间被用户移除了

    await _askNotificationPermission();
    final transfer = await FileDownloader().transfers.start(
      UriDownloadTask(
        url: url,
        directoryUri: dir,
        filename: entry.fileName,
        metaData: track.id,
        transferHints: const {TransferHint.userInitiated, TransferHint.largeFile},
      ),
    );
    _transfers[track.id] = transfer;
    _watch(transfer, entry);
    logger.output('[online] 开始下载 ${entry.fileName} @$q');
    return null;
  }

  OnlineDownloadEntry? entryOf(String trackId) =>
      entries.value.where((entry) => entry.trackId == trackId).firstOrNull;

  Future<void> pause(String trackId) async => _transfers[trackId]?.pause();

  Future<void> resume(String trackId) async => _transfers[trackId]?.resume();

  Future<void> cancel(String trackId) async => _transfers[trackId]?.cancel();

  void remove(String trackId) {
    _transfers.remove(trackId);
    entries.value.removeWhere((entry) => entry.trackId == trackId);
    _notify();
  }

  void clearFinished() {
    for (final entry in entries.value.where((e) => !e.state.isActive)) {
      _transfers.remove(entry.trackId);
    }
    entries.value.removeWhere((entry) => !entry.state.isActive);
    _notify();
  }

  /// 在系统文件管理器里打开下载目录。移动端没有通用接口，返回 false 由调用方忽略。
  Future<bool> openDirectory() async {
    final dir = await _directoryUri();
    if (dir == null || dir.scheme != 'file') return false;
    final path = dir.toFilePath(windows: Platform.isWindows);
    final command = switch (Platform.operatingSystem) {
      'windows' => 'explorer',
      'macos' => 'open',
      _ => 'xdg-open',
    };
    try {
      final result = await Process.run(command, [path]);
      return result.exitCode == 0;
    } catch (e) {
      logger.output('[online] 打开下载目录失败: $e');
      return false;
    }
  }

  /// 当前下载目录；没设置或权限恢复失败时返回 null。
  Future<Uri?> _directoryUri() async {
    final uri = Uri.tryParse(onlineSettings.downloadDir.value);
    return uri == null ? null : FileDownloader().uri.activate(uri);
  }

  void _watch(Transfer transfer, OnlineDownloadEntry entry) {
    void sync() {
      final status = transfer.statusNotifier.value;
      entry.state = switch (status) {
        .enqueued => OnlineDownloadState.enqueued,
        .running => OnlineDownloadState.running,
        .paused => OnlineDownloadState.paused,
        .complete => OnlineDownloadState.complete,
        .canceled => OnlineDownloadState.canceled,
        _ => OnlineDownloadState.failed,
      };
      final progress = transfer.progressNotifier.value;
      if (progress != null) entry.progress = progress;
      if (status == TaskStatus.complete) entry.progress = 1;
      _notify();
    }

    transfer.statusNotifier.addListener(sync);
    transfer.progressNotifier.addListener(sync);
    transfer.result.then((update) {
      entry.error ??= switch (update.status) {
        .notFound => '资源不存在（404）',
        .failed => update.exception?.description ?? '下载失败',
        .canceled => '已取消',
        _ => null,
      };
      sync();
      logger.output(
        '[online] 下载结束 ${entry.fileName}: ${update.status.name} ${entry.error ?? ''}',
      );
    });
    sync();
  }

  /// ValueNotifier 按引用比较，原地改列表不会触发重建，所以换一个新列表。
  void _notify() => entries.value = List<OnlineDownloadEntry>.of(entries.value);

  /// Android 13+ 的通知权限只影响能否看到通知，被拒也照样下载，所以只问一次。
  Future<void> _askNotificationPermission() async {
    if (!Platform.isAndroid || _notificationAsked) return;
    _notificationAsked = true;
    await Permission.notification.request();
  }

  static String _defaultQuality(OnlineTrack track) {
    final own = track.qualitys;
    if (own.contains(onlineSettings.quality.value)) {
      return onlineSettings.quality.value;
    }
    return own.isEmpty ? '128k' : own.first;
  }

  static String _buildFileName(OnlineTrack track, String quality, Uri dir) {
    final ext = switch (quality) {
      'flac' || 'flac24bit' || 'master' => 'flac',
      _ => 'mp3',
    };
    var base = _sanitize('${track.singer} - ${track.name}');
    if (base.isEmpty) base = _sanitize(track.name);
    if (base.isEmpty) base = track.songmid;
    var name = '$base.$ext';

    // 重名只在桌面能探测（移动端是 content://，拿不到目录列表），撞了交给插件。
    if (dir.scheme == 'file') {
      final dirPath = dir.toFilePath(windows: Platform.isWindows);
      var index = 1;
      while (File(p.join(dirPath, name)).existsSync()) {
        name = '$base (${++index}).$ext';
      }
    }
    return name;
  }

  static String _sanitize(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
  }
}

final OnlineDownloader onlineDownloader = OnlineDownloader();
