import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/fmt.dart';
import 'models.dart';
import 'store.dart';

/// 「工具 → 下载工作」用的下载器。
///
/// 落盘位置优先用**应用专属外部目录**：
///   /storage/emulated/0/Android/data/<包名>/files/StudyHubTV
/// 这样从安卓 5 到 14 都不需要申请任何存储权限，插上 U 盘也能用文件管理器
/// 从 Android/data 里找到（部分电视自带文件管理器会隐藏这个目录，
/// 所以界面上把完整路径也显示出来，方便用别的 App 找）。
///
/// 先写 .part 再改名：中途断了不会留下一个"看起来完整、实际半截"的文件。
class Downloader {
  Downloader._();

  static Directory? _dir;

  /// 用户在「设置 → 下载保存位置」里指定的目录；空 = 用默认的应用专属目录
  static String _custom() {
    try {
      return Store.instance.downloadDir;
    } catch (_) {
      return '';
    }
  }

  /// 指定的目录能不能用：建得出来、写得进去才算
  static Future<bool> _usable(Directory d) async {
    try {
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File('${d.path}${Platform.pathSeparator}.probe');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 默认目录：应用专属外部目录，任何安卓版本都不需要权限
  static Future<Directory> _defaultDir() async {
    final cached = _dir;
    if (cached != null && await cached.exists()) return cached;
    Directory base;
    try {
      base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final d = Directory('${base.path}${Platform.pathSeparator}StudyHubTV');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  static Future<Directory> targetDir() async {
    final want = _custom();
    if (want.isNotEmpty) {
      final d = Directory(want);
      if (await _usable(d)) return d;
      // 自定义目录不可用（U 盘拔了 / 没给全盘权限）时绝不静默失败，
      // 退回默认目录继续下，用户至少能拿到文件
      debugPrint('自定义下载目录不可用，退回默认目录：$want');
    }
    return _defaultDir();
  }

  /// 文件名里的非法字符换掉（服务器上的名字什么都有，不改的话创建文件会失败）
  static String safeName(String raw) {
    var n = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (n.isEmpty) n = 'download';
    if (n.length > 120) {
      final ext = extOf(n);
      final stem = stemOf(n);
      final cut = stem.length > 100 ? stem.substring(0, 100) : stem;
      n = '$cut${ext.isEmpty ? '' : '.$ext'}';
    }
    return n;
  }

  static Future<File> uniqueFile(Directory dir, String name) async {
    var f = File('${dir.path}${Platform.pathSeparator}$name');
    if (!await f.exists()) return f;
    final ext = extOf(name);
    final stem = stemOf(name);
    var i = 2;
    while (await f.exists()) {
      f = File('${dir.path}${Platform.pathSeparator}$stem ($i)'
          '${ext.isEmpty ? '' : '.$ext'}');
      i++;
      if (i > 999) break;
    }
    return f;
  }

  /// 本地是否已经有同名且大小一致的文件
  static Future<bool> alreadyDownloaded(String name, int size) async {
    try {
      final dir = await targetDir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      if (!await f.exists()) return false;
      if (size <= 0) return true;
      return await f.length() == size;
    } catch (_) {
      return false;
    }
  }

  /// 下载一个文件。[onProgress] 的 total 可能为 -1（服务器没给长度）
  static Future<File> fetch(
    MediaRef ref,
    String fileName, {
    required void Function(int received, int total) onProgress,
    CancelToken? cancel,
  }) async {
    final dir = await targetDir();
    final target = await uniqueFile(dir, safeName(fileName));
    final part = File('${target.path}.part');

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 30),
      followRedirects: true,
      maxRedirects: 5,
    ));

    try {
      await dio.download(
        ref.url,
        part.path,
        cancelToken: cancel,
        options: Options(
          headers: ref.headers.isEmpty ? null : ref.headers,
          // 只认 200/206：否则 401/404 的错误页会被当成文件存下来
          validateStatus: (s) => s == 200 || s == 206,
        ),
        onReceiveProgress: onProgress,
      );

      if (await part.exists() && await part.length() > 0) {
        if (await target.exists()) await target.delete();
        return part.rename(target.path);
      }
      throw Exception('服务器没有返回文件内容');
    } on DioException catch (e) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      throw Exception(_friendly(e));
    } catch (e) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    } finally {
      dio.close(force: true);
    }
  }

  static String _friendly(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401) return '下载失败：账号或密码不对（HTTP 401）';
    if (code == 403) return '下载失败：没有这个文件的读取权限（HTTP 403）';
    if (code == 404) return '下载失败：服务器上找不到这个文件（HTTP 404）';
    if (code != null) return '下载失败：HTTP $code';
    switch (e.type) {
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return '下载超时：网络太慢或服务器没响应';
      case DioExceptionType.connectionError:
        return '下载中断：连不上服务器（${e.message ?? ''}）';
      default:
        return '下载失败：${e.message ?? e.type.toString()}';
    }
  }
}
