import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:smb_connect/smb_connect.dart';

/// SMB 本地中转服务。
///
/// 为什么必须有这一层：
///   播放器（libmpv）和系统抽帧接口（MediaMetadataRetriever）都不会说 SMB，
///   它们只认 http(s) / file / 本地路径。而 smb_connect 给的是
///   Dart 的字节流和 RandomAccessFile —— 中间必须有东西把「按字节范围读
///   SMB 文件」翻译成「HTTP Range 请求」。
///
/// 做法：在 127.0.0.1 上开一个只听本机的 HTTP 服务（端口随机，不对外），
/// 播放器拿到的是 http://127.0.0.1:PORT/f?p=<SMB 路径>。
///
/// 这样还有一个额外好处：视频拖进度条、抽缩略图、图片解码全都走
/// 标准 HTTP，不用为 SMB 单独写三套适配。
///
/// 安全性：只 bind 到 loopback（127.0.0.1），外部网络连不进来；
/// 端口随机，且没有目录遍历接口（只认完整路径，路径来自我们自己的列表）。
class SmbBridge {
  SmbBridge(this._conn, this._resolve);

  final SmbConnect _conn;

  /// 把「绝对 SMB 路径」解析成 SmbFile（带缓存，避免每次请求都发一次 stat）
  final Future<SmbFile> Function(String absPath) _resolve;

  HttpServer? _server;
  int _port = 0;

  int get port => _port;
  bool get running => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.autoCompress = false;
    _server = s;
    _port = s.port;
    s.listen(
      (req) => _handle(req),
      onError: (Object e) => debugPrint('SMB 中转服务异常：$e'),
      cancelOnError: false,
    );
    debugPrint('SMB 中转服务已启动：http://127.0.0.1:$_port');
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  /// 给播放器 / 图片组件用的地址
  String urlFor(String absPath) =>
      'http://127.0.0.1:$_port/f?p=${Uri.encodeComponent(absPath)}';

  // ------------------------------------------------------------- 请求处理

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.uri.path != '/f') {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final p = req.uri.queryParameters['p'];
      if (p == null || p.isEmpty) {
        res.statusCode = HttpStatus.badRequest;
        await res.close();
        return;
      }

      final file = await _resolve(p);
      if (!file.isExists) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final size = file.size;

      res.headers.set('Accept-Ranges', 'bytes');
      res.headers.set('Content-Type', 'application/octet-stream');
      res.headers.set('Cache-Control', 'no-store');

      if (req.method == 'HEAD') {
        res.contentLength = size;
        await res.close();
        return;
      }

      var start = 0;
      var end = size - 1;
      var partial = false;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.startsWith('bytes=')) {
        final spec = range.substring(6).split(',')[0].trim();
        final dash = spec.indexOf('-');
        if (dash >= 0) {
          final a = spec.substring(0, dash);
          final b = spec.substring(dash + 1);
          // 支持 "bytes=1000-" 和 "bytes=-500"（结尾 500 字节）两种写法
          if (a.isEmpty && b.isNotEmpty) {
            final n = int.tryParse(b) ?? 0;
            start = n >= size ? 0 : size - n;
          } else {
            start = int.tryParse(a) ?? 0;
            if (b.isNotEmpty) {
              final e = int.tryParse(b);
              if (e != null) end = math.min(e, size - 1);
            }
          }
          partial = true;
        }
      }

      if (start >= size && size > 0) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set('Content-Range', 'bytes */$size');
        await res.close();
        return;
      }
      if (end < start) end = size - 1;

      final len = end - start + 1;
      if (partial) {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set('Content-Range', 'bytes $start-$end/$size');
      }
      res.contentLength = len;
      await _pipe(file, start, len, res);
      await res.close();
    } catch (e) {
      debugPrint('SMB 中转请求失败：$e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  /// 从 SMB 文件的 [start] 位置开始，往响应里写 [len] 字节。
  Future<void> _pipe(SmbFile file, int start, int len, HttpResponse res) async {
    if (len <= 0) return;

    // 首选「随机定位 + 分块读」：长度完全可控，播放器拖进度条最稳。
    RandomAccessFile? raf;
    try {
      raf = await _conn.open(file, mode: FileMode.read);
      await raf.setPosition(start);
      var left = len;
      while (left > 0) {
        final chunk = await raf.read(math.min(65536, left));
        if (chunk.isEmpty) break;
        left -= chunk.length;
        res.add(chunk);
      }
      return;
    } catch (e) {
      // 有些 SMB 服务端 / 老版本固件不支持随机读，退回顺序流。
      // 注意 openRead 的 [end] 在不同实现里含不含末尾有歧义，
      // 所以下面用 _capFor 兜住，最多只会少几个字节，绝不会多发给 HTTP 客户端。
      debugPrint('SMB 随机读失败，改用顺序流：$e');
    } finally {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
    }

    final stream = await _conn.openRead(file, start, start + len - 1);
    await res.addStream(_capFor(stream, len));
  }

  /// 把字节流截断到最多 [max] 字节
  Stream<List<int>> _capFor(Stream<Uint8List> src, int max) async* {
    var left = max;
    await for (final chunk in src) {
      if (left <= 0) break;
      if (chunk.length <= left) {
        left -= chunk.length;
        yield chunk;
      } else {
        yield chunk.sublist(0, left);
        left = 0;
        break;
      }
    }
  }
}
