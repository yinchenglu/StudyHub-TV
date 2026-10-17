import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/constants.dart';

/// 入口做三件事：
///   1. 初始化播放器内核（media_kit 内部是 libmpv，全格式解码）
///   2. 锁成横屏 + 隐藏系统栏 —— 电视上不该看到状态栏
///   3. 版本号一致性自检（改版本时 pubspec 和 constants 必须一起改）
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
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
