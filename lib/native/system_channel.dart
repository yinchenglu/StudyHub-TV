import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';

/// 电视上一个已安装应用
class InstalledApp {
  const InstalledApp({
    required this.package,
    required this.label,
    required this.icon,
    this.system = false,
    this.self = false,
  });

  final String package;
  final String label;

  /// 96×96 PNG 字节，取不到就是 null（画个默认图标顶上）
  final Uint8List? icon;

  /// 系统应用：一般不显示卸载，误删了电视会坏
  final bool system;

  /// 就是本应用
  final bool self;

  /// 包名里带这些的不太可能是"用户想管理"的应用
  bool get hideByDefault => system || self;
}

/// 内存概况（字节）
class MemInfo {
  const MemInfo({
    required this.avail,
    required this.total,
    required this.appUsed,
    required this.appMax,
    this.low = false,
    this.threshold = 0,
  });

  final int avail;
  final int total;

  /// 本应用 JVM 堆当前占用 / 上限
  final int appUsed;
  final int appMax;

  /// 系统已经处于低内存状态
  final bool low;

  /// 低于这个可用量系统就开始杀进程
  final int threshold;

  int get used => total - avail;
  double get usedRatio => total <= 0 ? 0 : used / total;
}

/// 原生系统能力的 Dart 侧封装（对应 android_custom/MainActivity.kt）。
///
/// 全部方法在**非安卓环境**（桌面调试、单元测试）下都返回"空"而不是抛异常 ——
/// 工具页在桌面上点开只该是一片"当前设备不支持"，不该红屏。
class SystemChannel {
  SystemChannel._();

  static const MethodChannel _ch = MethodChannel(kSystemChannel);

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 已安装应用列表。按"第三方在前、同组按名字"排好序返回。
  static Future<List<InstalledApp>> apps() async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('apps');
      if (raw == null) return const [];
      final out = <InstalledApp>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final pkg = e['package'] as String? ?? '';
        if (pkg.isEmpty) continue;
        final ic = e['icon'];
        out.add(InstalledApp(
          package: pkg,
          label: e['label'] as String? ?? pkg,
          icon: ic is Uint8List ? ic : null,
          system: e['system'] == true,
          self: e['self'] == true,
        ));
      }
      return out;
    } on MissingPluginException {
      debugPrint('系统通道不存在（非安卓环境？）');
      return const [];
    } catch (e) {
      debugPrint('读取应用列表失败：$e');
      return const [];
    }
  }

  /// 内存概况，读不到返回 null
  static Future<MemInfo?> memory() async {
    if (!_isAndroid) return null;
    try {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('memory');
      if (m == null) return null;
      int v(String k) => (m[k] as num?)?.toInt() ?? 0;
      return MemInfo(
        avail: v('avail'),
        total: v('total'),
        appUsed: v('appUsed'),
        appMax: v('appMax'),
        low: m['low'] == true,
        threshold: v('threshold'),
      );
    } catch (e) {
      debugPrint('读取内存信息失败：$e');
      return null;
    }
  }

  /// 清本应用的缓存目录，返回释放的字节数
  static Future<int> clearCache() async {
    if (!_isAndroid) return 0;
    try {
      return await _ch.invokeMethod<int>('clearCache') ?? 0;
    } catch (e) {
      debugPrint('清缓存失败：$e');
      return 0;
    }
  }

  /// 弹系统卸载确认框。注意：确认框是系统弹的，App 收不到结果，
  /// 回到页面时要自己重新拉一次列表。
  static Future<bool> uninstall(String package) async {
    if (!_isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('uninstall', {'package': package}) ??
          false;
    } catch (e) {
      debugPrint('调用卸载失败：$e');
      return false;
    }
  }

  /// 启动另一个应用
  static Future<bool> launch(String package) async {
    if (!_isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('launch', {'package': package}) ??
          false;
    } catch (e) {
      debugPrint('启动应用失败：$e');
      return false;
    }
  }

  /// 打开系统里的"应用详情"页
  static Future<bool> appInfo([String? package]) async {
    if (!_isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('appInfo', {'package': package}) ??
          false;
    } catch (e) {
      debugPrint('打开应用详情失败：$e');
      return false;
    }
  }

  /// 用系统应用打开本地文件（APK 会弹安装器，视频弹选择播放器）
  static Future<bool> openFile(String path) async {
    if (!_isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('openFile', {'path': path}) ?? false;
    } catch (e) {
      debugPrint('打开文件失败：$e');
      return false;
    }
  }

  /// 打开本机/厂商的自启动管理页。
  /// 返回命中的页面描述（空字符串 = 没找到，已退回应用详情页）。
  static Future<String> openAutostart() async {
    if (!_isAndroid) return '';
    try {
      return await _ch.invokeMethod<String>('openAutostart') ?? '';
    } catch (e) {
      debugPrint('打开自启动管理失败：$e');
      return '';
    }
  }
}
