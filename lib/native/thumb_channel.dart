import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';

/// 原生抽帧通道的 Dart 侧封装。
///
/// 抽帧为什么必须走原生：Dart 里没有能解 mp4/mkv 的库，
/// 而安卓自带 MediaMetadataRetriever 一行就能拿到一帧，
/// 而且它**支持直接吃 http 地址 + 请求头** —— 正好能带上 WebDAV 的
/// Basic Auth，不用先把整个视频下到本地（电视剧一集 2G，等不起）。
class ThumbChannel {
  ThumbChannel._();

  static const MethodChannel _ch = MethodChannel(kThumbChannel);

  /// 抽一帧，返回 JPEG 字节。失败返回 null（调用方静默降级成占位图标）。
  ///
  /// [url] 可以是 WebDAV 的完整地址，也可以是 SMB 中转服务的
  /// 127.0.0.1 地址。后者不需要请求头。
  static Future<Uint8List?> frame({
    required String url,
    Map<String, String> headers = const {},
    int width = 480,
    int timeoutMs = 8000,
  }) async {
    try {
      final r = await _ch.invokeMethod<Uint8List>('frame', {
        'url': url,
        'headers': headers,
        'width': width,
        'timeoutMs': timeoutMs,
      });
      if (r == null || r.isEmpty) return null;
      return r;
    } on MissingPluginException {
      // 桌面 / 单元测试环境没有原生实现，直接放弃
      debugPrint('抽帧通道不存在（非安卓环境？）');
      return null;
    } on PlatformException catch (e) {
      debugPrint('抽帧失败：${e.message}');
      return null;
    } catch (e) {
      debugPrint('抽帧异常：$e');
      return null;
    }
  }
}
