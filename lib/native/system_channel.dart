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

/// 一个信号源（只有电视机型才有）
class TvInput {
  const TvInput({required this.id, required this.label});

  final String id;
  final String label;
}

/// 后台在跑的第三方应用
class BgApp {
  const BgApp({required this.package, required this.label, this.pid = 0});

  final String package;
  final String label;
  final int pid;
}

/// 一次清后台的结果
class CleanResult {
  const CleanResult({
    required this.killed,
    required this.before,
    required this.after,
  });

  final int killed;

  /// 清理前后系统可用内存（字节）
  final int before;
  final int after;

  /// 实际多出来的可用内存；系统同时在干别的，可能是 0
  int get freed => after > before ? after - before : 0;
}

/// 一个会开机自启动的应用
class BootApp {
  const BootApp({
    required this.package,
    required this.label,
    required this.enabled,
    required this.system,
  });

  final String package;
  final String label;

  /// false = 已经被禁用（等价于自启动被关掉）
  final bool enabled;
  final bool system;
}

/// 存储环境
class StorageInfo {
  const StorageInfo({
    required this.roots,
    required this.emulated,
    required this.appDir,
    required this.allFiles,
  });

  /// /storage 下的挂载点，例如 /storage/emulated/0、/storage/1234-ABCD
  final List<String> roots;

  /// 内置存储根目录
  final String emulated;

  /// 本应用专属目录（不需要任何权限就能读写）
  final String appDir;

  /// 有没有"所有文件访问"权限（安卓 11+ 要用户手动开）
  final bool allFiles;
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

  // ------------------------------------------------------------ v1.5 新增

  /// 打开系统设置首页。
  ///
  /// 返回命中的入口描述（空字符串 = 所有入口都没命中，已退到本应用详情页）。
  /// 不同电视的"设置"入口完全不一样，原生侧是一层层兜底试出来的，
  /// 把命中方式带回来，界面才能告诉用户"到底怎么打开的"。
  static Future<String> openSystemSettings() async {
    if (!_isAndroid) return '';
    try {
      return await _ch.invokeMethod<String>('openSystemSettings') ?? '';
    } catch (e) {
      debugPrint('打开系统设置失败：$e');
      return '';
    }
  }

  /// 打开信号源切换界面。
  /// 返回："input:xxx" = 真进了信号源界面；"settings" = 只打开了系统设置；
  ///      空字符串 = 什么都没打开。
  static Future<String> openInputSource() async {
    if (!_isAndroid) return '';
    try {
      return await _ch.invokeMethod<String>('openInputSource') ?? '';
    } catch (e) {
      debugPrint('打开信号源失败：$e');
      return '';
    }
  }

  /// 系统里登记的信号源（手机是空列表）
  static Future<List<TvInput>> tvInputs() async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('tvInputs');
      if (raw == null) return const [];
      return [
        for (final e in raw)
          if (e is Map && (e['id'] as String?)?.isNotEmpty == true)
            TvInput(
              id: e['id'] as String,
              label: e['label'] as String? ?? '${e['id']}',
            ),
      ];
    } catch (e) {
      debugPrint('读取信号源失败：$e');
      return const [];
    }
  }

  /// 后台在跑的第三方应用
  static Future<List<BgApp>> bgApps() async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('bgApps');
      if (raw == null) return const [];
      return [
        for (final e in raw)
          if (e is Map && (e['package'] as String?)?.isNotEmpty == true)
            BgApp(
              package: e['package'] as String,
              label: e['label'] as String? ?? '${e['package']}',
              pid: (e['pid'] as num?)?.toInt() ?? 0,
            ),
      ];
    } catch (e) {
      debugPrint('读取后台应用失败：$e');
      return const [];
    }
  }

  /// 清掉后台第三方应用（桌面、系统应用、本应用不动）
  static Future<CleanResult?> cleanBackground() async {
    if (!_isAndroid) return null;
    try {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('cleanBackground');
      if (m == null) return null;
      int v(String k) => (m[k] as num?)?.toInt() ?? 0;
      return CleanResult(
        killed: v('killed'),
        before: v('before'),
        after: v('after'),
      );
    } catch (e) {
      debugPrint('清后台失败：$e');
      return null;
    }
  }

  /// 把某个应用的安装包提取到本机，返回文件路径（失败时空字符串）
  static Future<String> extractApk(String package) async {
    if (!_isAndroid) return '';
    try {
      return await _ch.invokeMethod<String>('extractApk',
              {'package': package}) ??
          '';
    } catch (e) {
      debugPrint('提取安装包失败：$e');
      return '';
    }
  }

  /// 压缩。返回写入的条目数，-1 = 失败
  static Future<int> zip(List<String> paths, String outPath) async {
    if (!_isAndroid) return -1;
    try {
      return await _ch.invokeMethod<int>('zip',
              {'paths': paths, 'out': outPath}) ??
          -1;
    } catch (e) {
      debugPrint('压缩失败：$e');
      return -1;
    }
  }

  /// 解压。返回解出的文件数，-1 = 失败
  static Future<int> unzip(String zipPath, String dir) async {
    if (!_isAndroid) return -1;
    try {
      return await _ch.invokeMethod<int>('unzip',
              {'zip': zipPath, 'dir': dir}) ??
          -1;
    } catch (e) {
      debugPrint('解压失败：$e');
      return -1;
    }
  }

  /// 存储根目录 / 权限状态
  static Future<StorageInfo?> storage() async {
    if (!_isAndroid) return null;
    try {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('storage');
      if (m == null) return null;
      final roots = <String>[
        for (final r in (m['roots'] as List<dynamic>? ?? const []))
          if (r is String) r,
      ];
      return StorageInfo(
        roots: roots,
        emulated: m['emulated'] as String? ?? '',
        appDir: m['appDir'] as String? ?? '',
        allFiles: m['allFiles'] == true,
      );
    } catch (e) {
      debugPrint('读取存储信息失败：$e');
      return null;
    }
  }

  /// 去系统里申请"所有文件访问"（安卓 11+）
  static Future<bool> requestAllFiles() async {
    if (!_isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('requestAllFiles') ?? false;
    } catch (e) {
      debugPrint('申请文件权限失败：$e');
      return false;
    }
  }

  /// 会开机自启动的应用
  static Future<List<BootApp>> bootApps() async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('bootApps');
      if (raw == null) return const [];
      return [
        for (final e in raw)
          if (e is Map && (e['package'] as String?)?.isNotEmpty == true)
            BootApp(
              package: e['package'] as String,
              label: e['label'] as String? ?? '${e['package']}',
              enabled: e['enabled'] != false,
              system: e['system'] == true,
            ),
      ];
    } catch (e) {
      debugPrint('读取自启动列表失败：$e');
      return const [];
    }
  }

  /// 禁止 / 恢复一个应用（需要 root 或系统权限，失败会返回 ok=false + 原因）
  static Future<(bool, String)> setBootEnabled(
      String package, bool enable) async {
    if (!_isAndroid) return (false, '当前环境不支持');
    try {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>(
          'setBootEnabled', {'package': package, 'enable': enable});
      if (m == null) return (false, '系统没有返回结果');
      return (m['ok'] == true, m['msg'] as String? ?? '');
    } catch (e) {
      return (false, '$e');
    }
  }
}
