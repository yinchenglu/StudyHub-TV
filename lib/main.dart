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

  // 不再锁横屏：电视没有重力感应，本来就是横的；但手机装这个 App 时，
  // 强制横屏会把界面整个转过去、内容被压成一条（就是"显示不全"）。
  // 现在跟随设备方向，窄屏自动换成底部导航（见 core/layout.dart）。
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
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
