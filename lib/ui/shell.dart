import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'account_edit_page.dart';
import 'account_panel.dart';
import 'browser_panel.dart';
import 'keys.dart';
import 'settings_panel.dart';
import 'sidebar.dart';
import 'tools_panel.dart';
import 'tv_widgets.dart';

/// 唯一的界面：左边主菜单 + 右边内容区。
///
/// 焦点模型（整个 App 的关键设计，改之前先读这里）：
///   * 左侧菜单整条只占 1 个 FocusNode，上下键自己算 index
///   * 内容区也只有一个 FocusNode，由具体面板自己算 index
///   * 只有两个区域，所以"焦点在谁身上"用一个 bool 就能表达，
///     不需要 Flutter 的焦点遍历树 —— 那套在电视上经常会跳到奇怪的格子
class Shell extends StatefulWidget {
  const Shell({super.key, required this.app});

  final AppState app;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  /// 菜单顺序：媒体三项 + 系统三项
  static const List<Section> _menu = [
    Section.images,
    Section.videos,
    Section.audio,
    Section.accounts,
    Section.settings,
    Section.tools,
  ];

  int _menuIndex = 0;
  final FocusNode _menuNode = FocusNode(debugLabel: 'menu');
  final FocusNode _contentNode = FocusNode(debugLabel: 'content');

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _menuNode.addListener(_redraw);
    _contentNode.addListener(_redraw);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await app.boot();
      if (!mounted) return;
      final i = _menu.indexWhere((s) => s == app.section);
      setState(() => _menuIndex = i < 0 ? 0 : i);
      // 开机直接把焦点给内容区：用户拿遥控第一下就想选片，
      // 不该先按一次"右键"才进得去
      _contentNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _menuNode.removeListener(_redraw);
    _contentNode.removeListener(_redraw);
    _menuNode.dispose();
    _contentNode.dispose();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------- 菜单按键

  KeyEventResult _onMenuKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;

    if (isUp(e)) {
      _moveMenu(-1);
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      _moveMenu(1);
      return KeyEventResult.handled;
    }
    if (isRight(e) || isSelect(e)) {
      _contentNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (isMenu(e)) {
      app.refresh();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveMenu(int d) {
    var i = _menuIndex + d;
    if (i < 0) i = _menu.length - 1; // 上下回绕，按到头再按一下回到另一端
    if (i >= _menu.length) i = 0;
    setState(() => _menuIndex = i);
    app.setSection(_menu[i]);
  }

  void _toMenu() => _menuNode.requestFocus();

  // ------------------------------------------------------------- 返回键

  /// 返回键的三层含义（从内到外）：
  ///   1. 内容区里在子目录 → 回上一级
  ///   2. 其他情况 → 焦点回左侧菜单
  ///   3. 已经在菜单上 → 退出 App
  Future<void> _handleBack() async {
    if (!_menuNode.hasFocus) {
      if (app.section.isMedia && app.cwd.isNotEmpty) {
        await app.up();
        return;
      }
      _toMenu();
      return;
    }
    await SystemNavigator.pop();
  }

  // ------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: TvColors.bg,
        body: SafeArea(
          child: AnimatedBuilder(
            animation: app,
            builder: (context, _) => Row(
              children: [
                Sidebar(
                  app: app,
                  focusNode: _menuNode,
                  items: _menu,
                  index: _menuIndex,
                  onKey: _onMenuKey,
                  onTap: (i) {
                    setState(() => _menuIndex = i);
                    app.setSection(_menu[i]);
                    _contentNode.requestFocus();
                  },
                  onAccount: () {
                    final i = _menu.indexOf(Section.accounts);
                    setState(() => _menuIndex = i);
                    app.setSection(Section.accounts);
                    _contentNode.requestFocus();
                  },
                ),
                Expanded(
                  child: ColoredBox(
                    color: TvColors.bg,
                    child: _content(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content() {
    if (app.booting) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 2.6),
            ),
            SizedBox(height: 18),
            Text('正在启动…',
                style: TextStyle(fontSize: 15, color: TvColors.textDim)),
          ],
        ),
      );
    }

    if (app.account == null) {
      return _Welcome(onAdd: _addAccount);
    }

    // 连不上：把原因和出口都给出来，别让用户对着空列表猜
    if (!app.connected && app.error != null) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ErrorBox(
              message: app.error!,
              onRetry: app.connectCurrent,
              focused: _contentNode.hasFocus,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LinkBtn(label: '换个账号', onTap: () => _go(Section.accounts)),
                const SizedBox(width: 14),
                _LinkBtn(label: '改地址', onTap: () => _addAccount(edit: true)),
              ],
            ),
          ],
        ),
      );
    }

    switch (app.section) {
      case Section.images:
      case Section.videos:
      case Section.audio:
        return BrowserPanel(
          app: app,
          focusNode: _contentNode,
          onRequestMenu: _toMenu,
          onOpenAccountEdit: () => _addAccount(edit: true),
        );
      case Section.accounts:
        return AccountPanel(
          app: app,
          focusNode: _contentNode,
          onRequestMenu: _toMenu,
        );
      case Section.settings:
        return SettingsPanel(
          app: app,
          focusNode: _contentNode,
          onRequestMenu: _toMenu,
        );
      case Section.tools:
        return ToolsPanel(
          app: app,
          focusNode: _contentNode,
          onRequestMenu: _toMenu,
        );
    }
  }

  void _go(Section s) {
    final i = _menu.indexOf(s);
    setState(() => _menuIndex = i < 0 ? 0 : i);
    app.setSection(s);
  }

  void _addAccount({bool edit = false}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AccountEditPage(
        app: app,
        account: edit ? app.account : null,
      ),
    ));
  }
}

/// 首次使用（一个账号都没有）时的引导页
class _Welcome extends StatelessWidget {
  const _Welcome({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                  colors: [TvColors.accent, Color(0xFF1E8FA8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Icon(Icons.play_arrow_rounded,
                  size: 60, color: Color(0xFF06222B)),
            ),
            const SizedBox(height: 26),
            const Text(
              '欢迎使用 $kAppName',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            const Text(
              '把 NAS 里存的图片、视频、音乐，用遥控器直接放到电视上看。\n'
              '不需要刮削、不需要整理目录，你原来的文件夹长什么样，这里就长什么样。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, height: 1.8, color: TvColors.textDim),
            ),
            const SizedBox(height: 30),
            FilledButton.icon(
              autofocus: true,
              onPressed: onAdd,
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('添加我的第一个账号'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              '支持 WebDAV（群晖 / 威联通 / Alist / Nextcloud）和 SMB（Windows 共享 / NAS 共享文件夹）',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: TvColors.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkBtn extends StatelessWidget {
  const _LinkBtn({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            color: TvColors.card,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: const TextStyle(fontSize: 14, color: TvColors.focus)),
        ),
      );
}
