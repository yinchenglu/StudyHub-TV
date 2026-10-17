import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'account_edit_form.dart';
import 'list_panel.dart';
import 'pair_page.dart';
import 'tv_widgets.dart';

/// 「账户」面板：切换 / 新增 / 编辑 / 删除 / 手机扫码填写。
///
/// v1.2 改动：
///   * 菜单里「账户」挪到最上面（其他分区都跟着它走）
///   * 「添加 / 编辑账号」不再是跳一个新页面，直接在这个面板内部切换 ——
///     遥控器按返回就是一键回列表，不会有一层层退不出去的感觉
///   * 增加「手机扫码填写」：电视上打密码太痛苦，让手机来填
class AccountPanel extends StatefulWidget {
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
  State<AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<AccountPanel> {
  /// 正在编辑的账号；null + [creating] = 新增
  Account? _editing;
  bool _creating = false;

  bool get _inForm => _creating || _editing != null;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    // 返回键先在面板内部消化：表单状态下返回 = 回到账号列表
    app.backOwner = this;
    app.backHandler = _onBack;
  }

  @override
  void dispose() {
    if (app.backOwner == this) {
      app.backHandler = null;
      app.backOwner = null;
    }
    super.dispose();
  }

  bool _onBack() {
    if (!_inForm) return false;
    setState(() {
      _creating = false;
      _editing = null;
    });
    _focusList();
    return true;
  }

  /// 回到列表后把焦点交给列表（等这一帧画完，Focus 节点才挂得上）
  void _focusList() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 面板被切走再切回来时，避免停在旧表单里
    return _inForm ? _form() : _list(context);
  }

  // ------------------------------------------------------------- 列表

  Widget _list(BuildContext context) {
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
        onTap: () => setState(() {
          _creating = true;
          _editing = null;
        }),
      ),
      TvListItem(
        title: '手机扫码填写',
        subtitle: '电视上打字太麻烦？用手机扫码填地址和密码，填完自动同步',
        icon: Icons.qr_code_2_rounded,
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PairPage(app: app),
          ));
        },
      ),
      if (current != null)
        TvListItem(
          title: '编辑当前账号',
          subtitle: current.name,
          icon: Icons.edit_outlined,
          onTap: () => setState(() {
            _creating = false;
            _editing = current;
          }),
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

    final lib = app.libraryRoot;
    final compact = isCompact(context);
    return TvListPanel(
      title: '账户',
      subtitle: accounts.isEmpty
          ? '还没有账号。点「添加账号」，填上自己 NAS 的地址就能开始看片。'
          : '选中账号按 OK 切换；同一时间只有一个账号在用。',
      items: items,
      focusNode: widget.focusNode,
      onRequestMenu: widget.onRequestMenu,
      // 手机上把「添加账号」提到标题右边：不滚动就能看见，手指也好按
      headerAction: compact
          ? FilledButton.icon(
              onPressed: () => setState(() {
                _creating = true;
                _editing = null;
              }),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                textStyle: const TextStyle(fontSize: 14),
              ),
            )
          : null,
      footer: Text(
        '${lib.isEmpty ? '没识别到 StudyHub-TV 目录，当前按账号根目录浏览。\n' : '媒体库目录：$lib\n'}'
        '地址示例：群晖 http://192.168.1.10:5005   ·   '
        '威联通 http://192.168.1.10:8081   ·   '
        'Alist http://192.168.1.10:5244/dav',
        style: const TextStyle(fontSize: 13, height: 1.7, color: TvColors.textDim),
      ),
    );
  }

  // ------------------------------------------------------------- 表单

  Widget _form() {
    final editing = _editing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: _creating ? '添加账号' : '编辑账号',
          subtitle: '返回键可以直接回列表',
          leading: IconButton(
            onPressed: _onBack,
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回账户列表',
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: AccountEditForm(
                key: ValueKey(_creating ? 'new' : editing?.id),
                app: app,
                account: editing,
                onDone: (_) {
                  setState(() {
                    _creating = false;
                    _editing = null;
                  });
                  _focusList();
                },
                onCancel: _onBack,
              ),
            ),
          ),
        ),
        const StatusBar(text: '填完点「测试并保存」，一次就能验完地址和密码'),
      ],
    );
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
