import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../native/system_channel.dart';
import 'keys.dart';
import 'tv_widgets.dart';

/// 「工具 → 自启动管理」（v1.5：从"只能跳转"升级成"能看能开关"）。
///
/// 能做到什么程度，先说清楚：
///   * **能看**：注册了 BOOT_COMPLETED 广播的应用 = 会开机自启的应用，
///     这是系统里唯一可查的口径，列出来是准的。
///   * **能关**：关自启动本质是把整个应用 disable 掉，普通应用没这个权限，
///     只有 root 或系统签名能做。所以这里先试 `su -c pm disable-user`，
///     再试裸 `pm`，两条都不行就如实告诉你"要 root"，并给一个去系统页面的按钮。
///   * 有的 ROM 有自己的白名单（小米/华为那套），跟这里的 disable 是两回事，
///     root 也管不到，那种情况还是要走系统页面。
class AutostartPage extends StatefulWidget {
  const AutostartPage({super.key});

  @override
  State<AutostartPage> createState() => _AutostartPageState();
}

class _AutostartPageState extends State<AutostartPage> {
  final FocusNode _node = FocusNode(debugLabel: 'autostart');
  final ScrollController _scroll = ScrollController();

  List<BootApp> _apps = const [];
  bool _loading = true;
  bool _busy = false;
  int _index = 0;
  String _status = '';

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
    setState(() => _loading = true);
    final list = await SystemChannel.bootApps();
    if (!mounted) return;
    setState(() {
      _apps = list;
      _loading = false;
      _index = 0;
      if (list.isEmpty) {
        _status = '没读到会自启动的应用（系统可能不公开广播接收器列表）';
      }
    });
  }

  Future<void> _toggle(BootApp a) async {
    if (_busy) return;
    final want = !a.enabled; // 当前是"允许"就点成"禁止"
    setState(() {
      _busy = true;
      _status = '正在${want ? '恢复' : '禁止'}「${a.label}」…';
    });
    final (ok, msg) = await SystemChannel.setBootEnabled(a.package, want);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      setState(() => _status = want
          ? '已恢复「${a.label}」的自启动'
          : '已禁止「${a.label}」（应用已被停用，桌面图标可能变灰）');
      await _load();
    } else {
      setState(() => _status = '改不动「${a.label}」：需要 root 或系统权限');
      _explain(msg);
    }
  }

  void _explain(String msg) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: const Text('改不动，为什么？'),
        content: Text(
          '关掉别人的自启动，等于把那个应用整包停用（pm disable-user）。'
          '安卓只允许 root 或系统签名的应用这么做，普通应用没有这个权限。\n\n'
          '两条出路：\n'
          '1. 电视盒子已经 root 的 → 点下面「打开系统自启动管理」，在那边关；\n'
          '2. 没 root → 用系统自带的「自启动管理 / 应用启动管理」页面关。\n\n'
          '${msg.isEmpty ? '' : '系统返回：$msg'}',
          style: const TextStyle(fontSize: 13.5, height: 1.6),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openSystemPage();
            },
            child: const Text('打开系统自启动管理'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSystemPage() async {
    final hit = await SystemChannel.openAutostart();
    if (!mounted) return;
    setState(() => _status = hit.isEmpty
        ? '这台机器没有独立的自启动页，已打开应用详情'
        : '已打开系统自启动管理');
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
      _openSystemPage();
      return KeyEventResult.handled;
    }
    if (isSelect(e) || isRight(e)) {
      if (n > 0) _toggle(_apps[clampInt(_index, 0, n - 1)]);
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
              PageHeader(
                title: '自启动管理',
                subtitle: '${_apps.length} 个应用会开机自启',
                leading: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回工具',
                ),
                actions: [
                  TextButton.icon(
                    onPressed: _openSystemPage,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('系统页面'),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _load,
                    icon: const Icon(Icons.refresh_rounded),
                    tooltip: '刷新',
                  ),
                ],
              ),
              Expanded(child: _body()),
              StatusBar(
                text: _status.isNotEmpty
                    ? _status
                    : 'OK 禁止/恢复 · 菜单键 打开系统自启动页 · ← 返回',
                warn: _status.contains('改不动') || _status.contains('没读到'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_apps.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(pagePad(context) + 10),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.rocket_launch_outlined,
                  size: 54, color: TvColors.textDim),
              const SizedBox(height: 14),
              const Text('没读到会自启动的应用',
                  style: TextStyle(fontSize: 17, color: TvColors.text)),
              const SizedBox(height: 8),
              const Text(
                '有些系统不公开"谁注册了开机广播"，这种情况下只能用系统自带的自启动管理页。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.6, color: TvColors.textDim),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _openSystemPage,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('打开系统自启动管理'),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, c) => Center(
        child: SizedBox(
          width: c.maxWidth > 900 ? 900 : c.maxWidth,
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
                pagePad(context), 4, pagePad(context), 18),
            itemCount: _apps.length + 1,
            itemBuilder: (context, i) {
              if (i == _apps.length) return const _Tips();
              final a = _apps[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: SizedBox(
                  height: 64,
                  child: TvRow(
                    focused: _node.hasFocus && i == _index,
                    title: a.label,
                    subtitle: '${a.package}'
                        '${a.system ? ' · 系统应用' : ''}',
                    leading: Icon(
                      a.enabled
                          ? Icons.check_circle_outline
                          : Icons.block_outlined,
                      size: 21,
                      color: a.enabled ? TvColors.accent : TvColors.danger,
                    ),
                    trailing: Text(
                      a.enabled ? '允许' : '已禁止',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: a.enabled ? TvColors.accent : TvColors.danger,
                      ),
                    ),
                    onTap: () {
                      setState(() => _index = i);
                      _node.requestFocus();
                      _toggle(a);
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 底部提示：为什么这件事要看设备脸色
class _Tips extends StatelessWidget {
  const _Tips();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            '这里的"禁止"是把整个应用停用（pm disable-user）：'
            '停用后它不会开机自启，也不会在后台跑，但桌面图标可能变灰、需要时得手动恢复。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: TvColors.textDim),
          ),
          SizedBox(height: 8),
          Text(
            '普通应用没有这个权限，需要盒子已 root。没 root 的话，'
            '用各厂商自己的「自启动管理 / 应用启动管理」（点右上角「系统页面」）。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: TvColors.textDim),
          ),
          SizedBox(height: 8),
          Text(
            '小米/华为/OPPO/vivo 那套白名单由 ROM 自己管，root 也管不到，只能走系统页面。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: TvColors.textDim),
          ),
        ],
      ),
    );
  }
}
