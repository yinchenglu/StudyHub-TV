import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'account_edit_page.dart';
import 'list_panel.dart';
import 'tv_widgets.dart';

/// 「账户」面板：切换 / 新增 / 编辑 / 删除。
///
/// 交互取舍：电视上做不了"长按弹菜单"那种精细操作，
/// 所以所有动作都摊平成一行一项，用 OK 直接触发，最多按两次就能到位。
class AccountPanel extends StatelessWidget {
  const AccountPanel({
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
    final accounts = app.accounts;
    final current = app.account;

    final items = <TvListItem>[
      for (final a in accounts)
        TvListItem(
          title: a.name,
          subtitle: '${a.proto.label} · ${a.summary}'
              '${a.id == current?.id ? (app.connected ? ' · 已连接' : ' · 未连接') : ''}',
          icon: a.proto == Proto.smb
              ? Icons.folder_shared_outlined
              : Icons.cloud_outlined,
          trailingText: a.id == current?.id ? '使用中' : '切换',
          onTap: () {
            if (a.id == current?.id) {
              app.connectCurrent();
            } else {
              app.switchAccount(a.id);
            }
          },
        ),
      TvListItem(
        title: '添加账号',
        subtitle: '支持 WebDAV 和 SMB 两种协议',
        icon: Icons.add_circle_outline,
        onTap: () => _edit(context, null),
      ),
      if (current != null)
        TvListItem(
          title: '编辑当前账号',
          subtitle: current.name,
          icon: Icons.edit_outlined,
          onTap: () => _edit(context, current),
        ),
      if (current != null)
        TvListItem(
          title: '重新连接',
          subtitle: '改了服务器设置、或从休眠唤醒后连不上时用',
          icon: Icons.refresh_rounded,
          onTap: app.connectCurrent,
        ),
      if (current != null)
        TvListItem(
          title: '删除当前账号',
          subtitle: '只删电视上保存的配置，不动服务器上的文件',
          icon: Icons.delete_outline,
          danger: true,
          onTap: () => _confirmDelete(context, current),
        ),
    ];

    return TvListPanel(
      title: '账户',
      subtitle: accounts.isEmpty
          ? '还没有账号。点「添加账号」，填上自己 NAS 的地址就能开始看片。'
          : '选中账号按 OK 切换；同一时间只有一个账号在用。',
      items: items,
      focusNode: focusNode,
      onRequestMenu: onRequestMenu,
      footer: const Text(
        '地址示例：群晖 http://192.168.1.10:5005   ·   '
        '威联通 http://192.168.1.10:8081   ·   '
        'Alist http://192.168.1.10:5244/dav',
        style: TextStyle(fontSize: 13, height: 1.7, color: TvColors.textDim),
      ),
    );
  }

  void _edit(BuildContext context, Account? a) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AccountEditPage(app: app, account: a),
    ));
  }

  Future<void> _confirmDelete(BuildContext context, Account a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: Text('删除「${a.name}」？'),
        content: const Text('只删除电视上保存的地址和密码，服务器上的文件不会动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: TvColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await app.deleteAccount(a.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已删除「${a.name}」'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }
}
