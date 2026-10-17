import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fmt.dart';
import '../core/theme.dart';
import '../native/system_channel.dart';
import 'keys.dart';
import 'tv_widgets.dart';

/// 「工具 → 应用管理」：电视上装了什么、占多大、能卸谁。
///
/// 遥控器操作：
///   ↑↓     移动
///   OK     打开这个应用
///   →      应用详情（系统设置里那一页，能关权限、清数据）
///   菜单键  卸载（会先弹确认；系统应用和自己的应用不给卸）
///
/// 为什么把"卸载"放在菜单键而不是跟"打开"抢 OK：
///   电视上最常见的误操作就是连按两下 OK，卸载必须多按一下才安全。
class AppManagerPage extends StatefulWidget {
  const AppManagerPage({super.key});

  @override
  State<AppManagerPage> createState() => _AppManagerPageState();
}

class _AppManagerPageState extends State<AppManagerPage> {
  final FocusNode _node = FocusNode(debugLabel: 'apps');
  final ScrollController _scroll = ScrollController();

  List<InstalledApp> _apps = const [];
  bool _loading = true;
  int _index = 0;
  String _status = '';

  int get _thirdParty => _apps.where((a) => !a.system).length;

  @override
  void initState() {
    super.initState();
    _node.addListener(_redraw);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _node.requestFocus();
      _load();
    });
  }

  @override
  void dispose() {
    _node.removeListener(_redraw);
    _scroll.dispose();
    _node.dispose();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _status = '';
    });
    final list = await SystemChannel.apps();
    if (!mounted) return;
    setState(() {
      _apps = list;
      _loading = false;
      _index = 0;
      if (list.isEmpty) {
        _status = '没读到应用列表：电视可能限制了应用可见性，或当前不是安卓环境';
      }
    });
  }

  // ------------------------------------------------------------- 动作

  Future<void> _launch(InstalledApp a) async {
    if (a.self) {
      setState(() => _status = '这就是 StudyHub TV 自己');
      return;
    }
    final ok = await SystemChannel.launch(a.package);
    if (!mounted) return;
    setState(() {
      _status = ok ? '正在打开「${a.label}」' : '「${a.label}」没有可启动的界面（可能是系统组件）';
    });
    _node.requestFocus();
  }

  Future<void> _uninstall(InstalledApp a) async {
    if (a.self) {
      setState(() => _status = '不能卸载正在运行的 StudyHub TV');
      return;
    }
    if (a.system) {
      setState(() => _status = '「${a.label}」是系统应用，卸了电视可能开不了机，不给卸');
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: Text('卸载「${a.label}」？'),
        content: Text(
          '${a.package}\n\n卸载后这个应用的数据会一起清掉。'
          '系统会再弹一次确认框，那次也要点「确定」。',
          style: const TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载', style: TextStyle(color: TvColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true) {
      _node.requestFocus();
      return;
    }
    final ok = await SystemChannel.uninstall(a.package);
    if (!mounted) return;
    setState(() {
      _status = ok ? '已请求系统卸载「${a.label}」' : '卸载请求发不出去（电视不允许通过应用卸载）';
    });
    _node.requestFocus();
  }

  // ------------------------------------------------------------- 按键

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final n = _apps.length;

    if (isUp(e)) {
      _move(_index - 1);
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      _move(_index + 1);
      return KeyEventResult.handled;
    }
    if (isLeft(e)) {
      if (mounted) Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (isMenu(e)) {
      if (n > 0) _uninstall(_apps[clampInt(_index, 0, n - 1)]);
      return KeyEventResult.handled;
    }
    if (isSelect(e)) {
      if (n > 0) _launch(_apps[clampInt(_index, 0, n - 1)]);
      return KeyEventResult.handled;
    }
    if (isRight(e)) {
      if (n > 0) {
        final a = _apps[clampInt(_index, 0, n - 1)];
        SystemChannel.appInfo(a.package);
        setState(() => _status = '已打开「${a.label}」的系统详情页');
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int v) {
    if (_apps.isEmpty) return;
    final next = clampInt(v, 0, _apps.length - 1);
    if (next == _index) return;
    setState(() => _index = next);
    if (!_scroll.hasClients) return;
    const rowH = 70.0;
    final top = next * rowH;
    final vp = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.animateTo(top,
          duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
    } else if (top + rowH > _scroll.offset + vp) {
      _scroll.animateTo(top + rowH - vp,
          duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
    }
  }

  // ------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvColors.bg,
      body: SafeArea(
        child: Focus(
          focusNode: _node,
          onKeyEvent: _onKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              Expanded(child: _body()),
              StatusBar(
                text: _status.isNotEmpty
                    ? _status
                    : 'OK 打开 · → 系统详情 · 菜单键 卸载',
                warn: _status.contains('不能') || _status.contains('不允许'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回工具',
          ),
          const SizedBox(width: 6),
          const Text('应用管理',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              _loading
                  ? '正在读取…'
                  : '共 ${_apps.length} 个 · 第三方 $_thirdParty 个',
              style: const TextStyle(fontSize: 14, color: TvColors.textDim),
            ),
          ),
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_apps.isEmpty) {
      return EmptyHint(_status.isEmpty ? '没有读到应用' : _status,
          icon: Icons.apps_rounded);
    }
    return LayoutBuilder(
      builder: (context, c) => Center(
        child: SizedBox(
          width: c.maxWidth > 900 ? 900 : c.maxWidth,
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(22, 6, 22, 22),
            itemCount: _apps.length,
            itemBuilder: (context, i) => _row(_apps[i], i),
          ),
        ),
      ),
    );
  }

  Widget _row(InstalledApp a, int i) {
    final focused = _node.hasFocus && i == _index;
    final tag = a.self ? '本应用' : (a.system ? '系统' : '');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: SizedBox(
        height: 66,
        child: TvRow(
          focused: focused,
          title: a.label,
          subtitle: a.package,
          leading: _icon(a),
          trailing: tag.isEmpty
              ? const Icon(Icons.chevron_right, color: TvColors.textDim)
              : Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: TvColors.divider,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(tag,
                      style: const TextStyle(
                          fontSize: 12, color: TvColors.textDim)),
                ),
          onTap: () {
            setState(() => _index = i);
            _node.requestFocus();
            _launch(a);
          },
        ),
      ),
    );
  }

  Widget _icon(InstalledApp a) {
    final bytes = a.icon;
    if (bytes == null) {
      return const Icon(Icons.android_rounded, size: 30, color: TvColors.textDim);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: Image.memory(
        bytes,
        width: 34,
        height: 34,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Icon(Icons.android_rounded,
            size: 30, color: TvColors.textDim),
      ),
    );
  }
}
