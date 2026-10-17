import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../state/app_state.dart';
import 'app_manager_page.dart';
import 'autostart_page.dart';
import 'download_page.dart';
import 'file_manager_page.dart';
import 'list_panel.dart';
import 'memory_page.dart';

/// 「工具」面板：软件下载 / 文件管理 / 应用管理 / 内存清理 / 自启动管理。
///
/// 这五项的共同点：都是"离开媒体库去管点别的事"，
/// 所以统一推一个独立页面，而不是像设置那样就地切值 ——
/// 电视上层层叠叠的弹窗很容易把用户困住，独立页面按返回就能退出来。
///
/// 原来放在这里的「连接测试」「关于 / 诊断」挪去了「设置」，
/// 那两项是"一辈子看一两次"的东西，不该跟日常操作抢位置。
class ToolsPanel extends StatelessWidget {
  const ToolsPanel({
    super.key,
    required this.app,
    required this.focusNode,
    required this.onRequestMenu,
  });

  final AppState app;
  final FocusNode focusNode;
  final VoidCallback onRequestMenu;

  @override
  Widget build(BuildContext context) {
    void push(Widget page) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    }

    final items = <TvListItem>[
      TvListItem(
        title: '软件下载',
        subtitle: app.downloadBase.isEmpty
            ? '服务器上的 download 文件夹（还没连上账号）'
            : '从 ${app.downloadBase} 下载文件到电视本地',
        icon: Icons.download_rounded,
        onTap: () => push(DownloadPage(app: app)),
      ),
      TvListItem(
        title: '文件管理',
        subtitle: '看下载好的文件、装 APK、删缓存，腾出电视空间',
        icon: Icons.folder_open_rounded,
        onTap: () => push(const FileManagerPage()),
      ),
      TvListItem(
        title: '应用管理',
        subtitle: '电视上装了哪些应用、占多大，可以打开或卸载',
        icon: Icons.apps_rounded,
        onTap: () => push(const AppManagerPage()),
      ),
      TvListItem(
        title: '内存清理',
        subtitle: '看内存占用，一键清缓存（电视卡的时候用）',
        icon: Icons.memory_rounded,
        onTap: () => push(const MemoryPage()),
      ),
      TvListItem(
        title: '自启动管理',
        subtitle: '跳到系统的自启动开关，管开机启动哪些应用',
        icon: Icons.rocket_launch_outlined,
        onTap: () => push(const AutostartPage()),
      ),
    ];

    return TvListPanel(
      title: '工具',
      subtitle: '下载、文件、应用、内存 —— 都不影响服务器上的原文件。',
      items: items,
      focusNode: focusNode,
      onRequestMenu: onRequestMenu,
      footer: const Text(
        '提示：「软件下载」下到电视本地的是副本，删本地文件不会动服务器。',
        style: TextStyle(fontSize: 13, color: TvColors.textDim),
      ),
    );
  }
}
