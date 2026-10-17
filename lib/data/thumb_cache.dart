import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../native/thumb_channel.dart';

/// 视频缩略图缓存。
///
/// 三层，缺一层都会让电视上的体验崩掉：
///   1. **原生抽帧**（ThumbChannel）—— 只对没缓存的视频抽，抽一帧要发一次
///      网络请求 + 解码，很贵。
///   2. **磁盘缓存** —— 抽完落成 <应用目录>/thumbs/<md5>.jpg。
///      电视盒子重启后还在，第二次进同一个目录秒开。
///   3. **并发闸门 + 去重** —— 一屏十几个视频同时抽帧会把网络和 CPU
///      一起打满，列表滚动直接卡住。限制 2 个并发、同一个视频只抽一次。
///
/// 失败一律静默降级成占位图标：抽不出来的原因太多（老容器 rmvb、
/// 服务器不支持 Range、网络抖），任何一个都不该让整个列表报错。
class ThumbCache {
  ThumbCache._();
  static final ThumbCache instance = ThumbCache._();

  static const int _maxConcurrent = 2;

  final Map<String, Future<File?>> _inflight = {};
  final Map<String, File> _done = {};
  final Set<String> _failed = {};

  int _running = 0;
  Directory? _dir;
  bool _dirFailed = false;

  /// build() 里同步取（已缓存的），拿不到返回 null
  File? peek(String key) => _done[key];

  bool isFailed(String key) => _failed.contains(key);

  Future<Directory?> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    if (_dirFailed) return null;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}${Platform.pathSeparator}thumbs');
      if (!await d.exists()) await d.create(recursive: true);
      return _dir = d;
    } catch (e) {
      debugPrint('缩略图目录创建失败：$e');
      _dirFailed = true;
      return null;
    }
  }

  /// 取某个文件的缩略图。幂等：同一个 key 重复调用只真正抽一次。
  ///
  /// [key] 建议用「账号id|文件路径」，这样换服务器不会串图。
  Future<File?> get({
    required String key,
    required String url,
    Map<String, String> headers = const {},
    int width = 480,
  }) {
    final done = _done[key];
    if (done != null) return Future<File?>.value(done);
    if (_failed.contains(key)) return Future<File?>.value(null);

    final running = _inflight[key];
    if (running != null) return running;

    final fut = _run(key, url, headers, width);
    _inflight[key] = fut;
    fut.whenComplete(() => _inflight.remove(key));
    return fut;
  }

  Future<File?> _run(
    String key,
    String url,
    Map<String, String> headers,
    int width,
  ) async {
    final dir = await _ensureDir();
    if (dir == null) return null;

    final name = '${md5.convert(utf8.encode(key))}.jpg';
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    try {
      if (await f.exists() && await f.length() > 512) {
        _done[key] = f;
        return f;
      }
    } catch (_) {}

    // 并发闸门：简单轮询等待，比引入线程池依赖划算
    while (_running >= _maxConcurrent) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    _running++;
    try {
      final bytes = await ThumbChannel.frame(
        url: url,
        headers: headers,
        width: width,
      );
      if (bytes == null || bytes.isEmpty) {
        _failed.add(key);
        return null;
      }
      await f.writeAsBytes(bytes, flush: true);
      _done[key] = f;
      return f;
    } catch (e) {
      debugPrint('缩略图写入失败：$e');
      _failed.add(key);
      return null;
    } finally {
      _running--;
    }
  }

  /// 清空磁盘缓存（设置里「清理缩略图」用）
  Future<void> clear() async {
    _done.clear();
    _failed.clear();
    _inflight.clear();
    final dir = await _ensureDir();
    if (dir == null) return;
    try {
      await for (final e in dir.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('清空缩略图失败：$e');
    }
  }

  /// 当前缓存占用（字节）+ 文件个数
  Future<(int, int)> usage() async {
    final dir = await _ensureDir();
    if (dir == null) return (0, 0);
    var bytes = 0;
    var count = 0;
    try {
      await for (final e in dir.list()) {
        if (e is File) {
          try {
            bytes += await e.length();
            count++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return (bytes, count);
  }
}
