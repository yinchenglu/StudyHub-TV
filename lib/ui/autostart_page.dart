import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../native/system_channel.dart';
import 'list_panel.dart';

/// 「工具 → 自启动管理」。
///
/// 这页为什么只能做"跳转"而不是一个开关：
///   安卓从 5.0 到 14 都没有统一的自启动 API。每家 ROM 自行其是，
///   连原生 Android TV 都压根没有"自启动白名单"这个概念。
///   任何号称能一键开关自启动的 App，本质也是跳到厂商那个隐藏页面去，
///   或者要求 root。所以这里老老实实做两件事：
///     1. 按品牌挨个试内置的自启动管理页，试到一个就直接进；
///     2. 一个都试不到（原生电视盒子多半如此），就打开本应用的详情页，
///        让用户自己去权限里找。
///   页面下方把常见品牌的路径写清楚，用户照着点就行。
class AutostartPage extends StatefulWidget {
  const AutostartPage({super.key});

  @override
  State<AutostartPage> createState() => _AutostartPageState();
}

class _AutostartPageState extends State<AutostartPage> {
  final FocusNode _node = FocusNode(debugLabel: 'autostart');
  String _last = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _node.requestFocus();
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = <TvListItem>[
      TvListItem(
        title: '打开系统的自启动管理',
        subtitle: _last.isEmpty
            ? '自动按品牌匹配入口（小米 / 华为 / OPPO / vivo / 三星…）'
            : _last,
        icon: Icons.rocket_launch_outlined,
        onTap: _openAutostart,
      ),
      TvListItem(
        title: '打开 StudyHub TV 的应用详情',
        subtitle: '权限、通知、存储都在这一页，自启动选项有时也藏在这里',
        icon: Icons.info_outline,
        onTap: () async {
          final ok = await SystemChannel.appInfo();
          _toast(ok ? '已打开本应用的应用详情' : '打不开应用详情（系统不允许）');
        },
      ),
    ];

    // SnackBar 必须有 Scaffold 才显示得出来（TvListPanel 本身只是个 Column）
    return Scaffold(
      backgroundColor: TvColors.bg,
      body: SafeArea(
        child: TvListPanel(
          title: '自启动管理',
          subtitle: '电视上的自启动开关由系统管，这里帮你直接跳到那一页。',
          items: items,
          focusNode: _node,
          onRequestMenu: () {
            if (mounted) Navigator.of(context).pop();
          },
          footer: const _Tips(),
        ),
      ),
    );
  }

  Future<void> _openAutostart() async {
    final hit = await SystemChannel.openAutostart();
    if (!mounted) return;
    if (hit.isEmpty) {
      setState(() => _last = '没找到本机的自启动页，已打开应用详情');
      _toast('这台电视没有独立的自启动管理页，已打开「应用详情」。'
          '如果详情里也没有「自启动」，说明系统不限制，不用管它。');
    } else {
      setState(() => _last = '已打开：${hit.split('/').first}');
      _toast('已打开系统自启动管理');
      _node.requestFocus();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
    );
  }
}

/// 底部提示：各品牌自启动开关在哪儿
class _Tips extends StatelessWidget {
  const _Tips();

  @override
  Widget build(BuildContext context) {
    const items = <(String, String)>[
      ('小米 / Redmi 电视', '设置 → 应用 → 应用管理 → StudyHub TV → 自启动'),
      ('华为 / 荣耀', '手机管家 → 应用启动管理 → 找到 StudyHub TV'),
      ('OPPO / 一加', '设置 → 电池 → 应用耗电管理 / 自启动管理'),
      ('vivo', 'i管家 → 应用管理 → 权限管理 → 自启动'),
      ('创维 / 海信 / TCL', '设置 → 应用 → 权限管理 → 自启动（部分机型没有）'),
      ('原生 Android TV', '没有自启动白名单，开机启动谁由桌面决定，不用设置'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '各家电视的自启动菜单在哪',
          style: TextStyle(
              fontSize: 13,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
              color: TvColors.textDim),
        ),
        const SizedBox(height: 10),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 130,
                  child: Text(it.$1,
                      style: const TextStyle(
                          fontSize: 13, color: TvColors.text)),
                ),
                Expanded(
                  child: Text(it.$2,
                      style: const TextStyle(
                          fontSize: 13, color: TvColors.textDim)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        const Text(
          '说明：安卓没有统一的自启动接口，本页只负责把你送到系统那一页，'
          '开关本身由系统管。',
          style: TextStyle(fontSize: 12, height: 1.6, color: TvColors.textDim),
        ),
      ],
    );
  }
}
