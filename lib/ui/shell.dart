import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'account_panel.dart';
import 'browser_panel.dart';
import 'compact_nav.dart';
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
  /// 菜单顺序（v1.2）：账户最上面，然后才是媒体三项，最下面工具、设置
  static const List<Section> _menu = [
    Section.accounts,
    Section.images,
    Section.videos,
    Section.audio,
    Section.tools,
    Section.settings,
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
  ///   0. 当前面板自己要消化（例如账户面板正在填表单）→ 交给它
  ///   1. 内容区里在子目录 → 回上一级
  ///   2. 其他情况 → 焦点回左侧菜单
  ///   3. 已经在菜单上 → 退出 App
  Future<void> _handleBack() async {
    if (app.backHandler?.call() == true) return;

    // 手机（窄屏）没有左侧菜单，返回键的"回菜单"这一层不存在：
    // 在子目录里就回上一级，已经在分区根目录就直接退出 App。
    if (isCompact(context)) {
      if (app.section.isMedia) {
        if (await app.up()) return;
      }
      await SystemNavigator.pop();
      return;
    }

    if (!_menuNode.hasFocus) {
      if (app.section.isMedia) {
        // up() 内部保证不会退到分区根目录之上；退不动就说明已经到根了
        final moved = await app.up();
        if (moved) return;
      }
      _toMenu();
      return;
    }
    await SystemNavigator.pop();
  }

  // ------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    final compact = isCompact(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: TvColors.bg,
        // 手机上要留出键盘空间，否则填账号时输入框被键盘盖住
        resizeToAvoidBottomInset: true,
        // 窄屏的底部安全区交给 CompactNav 自己吃掉（它要用菜单底色铺满），
        // 其余情况还是交给 SafeArea
        body: SafeArea(
          bottom: !compact,
          child: AnimatedBuilder(
            animation: app,
            builder: (context, _) =>
                compact ? _compactBody() : _wideBody(),
          ),
        ),
      ),
    );
  }

  /// 宽屏（电视 / 平板横屏）：左侧固定菜单 + 右侧内容
  Widget _wideBody() {
    return Row(
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
            _go(Section.accounts);
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
    );
  }

  /// 窄屏（手机）：内容占满，菜单换成底部导航条
  Widget _compactBody() {
    return Column(
      children: [
        Expanded(
          child: ColoredBox(
            color: TvColors.bg,
            child: _content(),
          ),
        ),
        CompactNav(
          items: _menu,
          current: app.section,
          onTap: (i) {
            setState(() => _menuIndex = i);
            app.setSection(_menu[i]);
          },
        ),
      ],
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
      return _Welcome(onAdd: () => _go(Section.accounts));
    }

    // 连不上：把原因和出口都给出来，别让用户对着空列表猜
    if (!app.connected && app.error != null) {
      return Padding(
        padding: EdgeInsets.all(isCompact(context) ? 16 : 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ErrorBox(
              message: app.error!,
              onRetry: app.connectCurrent,
              focused: _contentNode.hasFocus,
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 14,
              runSpacing: 10,
              children: [
                _LinkBtn(label: '换个账号', onTap: () => _go(Section.accounts)),
                _LinkBtn(label: '改地址', onTap: () => _go(Section.accounts)),
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
          onNeedAccount: () => _go(Section.accounts),
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
}

/// 首次使用（一个账号都没有）时的引导页
class _Welcome extends StatelessWidget {
  const _Welcome({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final compact = isCompact(context);
    // 手机上"标题 + 说明 + 按钮"竖着排会超出屏幕（尤其横屏时，
    // 屏幕只有 360 高），所以整页可滚 —— 保证按钮任何时候都点得到。
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 20 : 32,
          vertical: compact ? 20 : 28,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight - (compact ? 40 : 56)),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: compact ? 74 : 92,
                    height: compact ? 74 : 92,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(compact ? 20 : 24),
                      gradient: const LinearGradient(
                        colors: [TvColors.accent, Color(0xFF1E8FA8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Icon(Icons.play_arrow_rounded,
                        size: compact ? 48 : 60, color: const Color(0xFF06222B)),
                  ),
                  SizedBox(height: compact ? 18 : 26),
                  Text(
                    '欢迎使用 $kAppName',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 22 : 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: compact ? 10 : 14),
                  Text(
                    '把 NAS 里存的图片、视频、音乐，用遥控器直接放到电视上看。\n'
                    '不需要刮削、不需要整理目录，你原来的文件夹长什么样，这里就长什么样。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 13.5 : 15,
                      height: 1.8,
                      color: TvColors.textDim,
                    ),
                  ),
                  SizedBox(height: compact ? 22 : 30),
                  SizedBox(
                    width: compact ? double.infinity : null,
                    child: FilledButton.icon(
                      autofocus: true,
                      onPressed: onAdd,
                      icon: const Icon(Icons.add_link_rounded),
                      label: const Text('添加我的第一个账号'),
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 16 : 30,
                          vertical: compact ? 16 : 20,
                        ),
                        textStyle: TextStyle(
                          fontSize: compact ? 16 : 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 16 : 22),
                  Text(
                    '支持 WebDAV（群晖 / 威联通 / Alist / Nextcloud）和 SMB（Windows 共享 / NAS 共享文件夹）',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 12 : 13,
                      color: TvColors.textDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
