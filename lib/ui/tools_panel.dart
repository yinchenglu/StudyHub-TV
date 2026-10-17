import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/fmt.dart';
import '../core/theme.dart';
import '../data/thumb_cache.dart';
import '../state/app_state.dart';
import 'list_panel.dart';

/// 「工具」面板：连接自检、清缓存、诊断信息。
/// 都是"点一下立刻有回音"的动作，结果显示在底部状态条。
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
    final items = <TvListItem>[
      TvListItem(
        title: '连接测试',
        subtitle: '检查账号、目录权限，以及视频能不能拖进度条',
        icon: Icons.network_check_rounded,
        onTap: () => _test(),
      ),
      TvListItem(
        title: '清理缩略图缓存',
        subtitle: '视频封面缓存在电视本地，删掉不影响服务器',
        icon: Icons.cleaning_services_outlined,
        onTap: () => _cleanThumbs(),
      ),
      TvListItem(
        title: '重新加载当前目录',
        subtitle: '服务器上新加了文件，用这个刷新出来',
        icon: Icons.refresh_rounded,
        onTap: app.refresh,
      ),
      TvListItem(
        title: '关于 / 诊断信息',
        subtitle: '版本号、当前协议、地址（发给别人求助时用）',
        icon: Icons.info_outline,
        onTap: () => _about(context),
      ),
    ];

    return TvListPanel(
      title: '工具',
      subtitle: '出问题时先跑一遍「连接测试」，它会把原因说成人话。',
      items: items,
      focusNode: focusNode,
      onRequestMenu: onRequestMenu,
    );
  }

  Future<void> _test() async {
    final src = app.source;
    if (src == null) {
      app.setStatus('还没连上服务器，先去「账户」检查地址和密码');
      return;
    }
    app.setStatus('正在测试…');
    try {
      final msg = await src.check();
      app.setStatus(msg);
    } catch (e) {
      app.setStatus('测试失败：$e');
    }
  }

  Future<void> _cleanThumbs() async {
    final before = await ThumbCache.instance.usage();
    await app.clearThumbs();
    app.setStatus(
      '已清理缩略图缓存：${before.$2} 个文件、${fmtBytes(before.$1)}',
    );
  }

  void _about(BuildContext context) {
    final a = app.account;
    final lines = [
      '版本：v$kAppVersion',
      '当前账号：${a?.name ?? '无'}',
      '协议：${a?.proto.label ?? '-'}',
      '地址：${a?.summary ?? '-'}',
      '状态：${app.connected ? '已连接' : '未连接'}',
      '',
      kRepoUrl,
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: const Text('关于 StudyHub TV'),
        content: SelectableText(
          lines.join('\n'),
          style: const TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
