import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/constants.dart';

/// 入口做三件事：
///   1. 初始化播放器内核（media_kit 内部是 libmpv，全格式解码）
///   2. 隐藏系统栏 —— 电视和播放器都不该看到状态栏
///   3. 版本号一致性自检（改版本时 pubspec 和 constants 必须一起改）
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // v1.5 起重新锁横屏（用户明确要求）：电视 / 盒子本来就该是横的，
  // 手机装上也是横着看片更合理。
  // 但"锁横屏"必须配"布局按高度自适应"，否则 360dp 高的手机横屏会把
  // 左侧菜单挤到屏幕外 —— 那部分在 ui/sidebar.dart 和 core/layout.dart 里：
  //   * 侧栏行高按可用高度分三档缩，菜单区可滚动并跟随焦点
  //   * 窄屏（<720dp 宽）走底部导航，不显示侧栏
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  assert(
    kAppVersion == kPubspecVersion.split('+').first,
    '版本号不一致：constants.dart=$kAppVersion，pubspec.yaml=$kPubspecVersion',
  );

  runApp(const StudyHubTvApp());
}
