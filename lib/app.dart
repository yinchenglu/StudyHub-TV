import 'package:flutter/material.dart';

import 'core/constants.dart';
import 'core/theme.dart';
import 'state/app_state.dart';
import 'ui/shell.dart';

class StudyHubTvApp extends StatefulWidget {
  const StudyHubTvApp({super.key});

  @override
  State<StudyHubTvApp> createState() => _StudyHubTvAppState();
}

class _StudyHubTvAppState extends State<StudyHubTvApp> {
  /// 全局只有一个状态对象。整个 App 就一个界面，
  /// 用 InheritedWidget / 状态库都算过度设计。
  final AppState _app = AppState();

  @override
  void dispose() {
    _app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      // 电视上系统字体缩放常被设成 1.3 / 1.5（老人机模式），
      // 不锁住会把布局撑破；换成固定的 1.0，我们自己的字号已经够大。
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: const TextScaler.linear(1.0)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: Shell(app: _app),
    );
  }
}
