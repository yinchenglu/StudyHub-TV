import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fmt.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../native/system_channel.dart';
import '../state/app_state.dart';
import 'app_manager_page.dart';
import 'autostart_page.dart';
import 'download_page.dart';
import 'file_manager_page.dart';
import 'keys.dart';
import 'memory_page.dart';
import 'tv_widgets.dart';

/// 「工具」面板（v1.5 改成卡片墙）。
///
/// 为什么从竖排列表改成卡片：
///   这几个工具彼此没有先后关系，是一排"入口"，卡片比长列表更好扫读，
///   电视上用方向键在二维网格里移动也比一路往下按更省事。
///
/// 卡片里混了两类东西：
///   * 推一个独立页面（软件下载 / 文件管理 / 应用管理 / 内存清理 / 自启动）
///   * 直接拉起系统界面（系统设置 / 信号源切换）—— 这两项点了就跳出去，
///     回来时还在这一页。
class ToolsPanel extends StatefulWidget {
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
  State<ToolsPanel> createState() => _ToolsPanelState();
}

class _ToolsPanelState extends State<ToolsPanel> {
  int _index = 0;
  int _cols = 3;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_redraw);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_redraw);
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  List<_Tool> get _tools => [
        _Tool(
          title: '软件下载',
          subtitle: app.downloadBase.isEmpty
              ? '服务器上的 download 文件夹（还没连上账号）'
              : '从 ${app.downloadBase} 下到电视本地',
          icon: Icons.download_rounded,
          onTap: () => _push(DownloadPage(app: app)),
        ),
        _Tool(
          title: '文件管理',
          subtitle: '整机文件：复制 / 剪切 / 压缩 / 解压 / 上传',
          icon: Icons.folder_open_rounded,
          onTap: () => _push(FileManagerPage(app: app)),
        ),
        _Tool(
          title: '应用管理',
          subtitle: '启动、卸载、提取安装包、看详情',
          icon: Icons.apps_rounded,
          onTap: () => _push(const AppManagerPage()),
        ),
        _Tool(
          title: '内存清理',
          subtitle: '清缓存 + 杀后台第三方应用',
          icon: Icons.memory_rounded,
          onTap: () => _push(const MemoryPage()),
        ),
        _Tool(
          title: '自启动管理',
          subtitle: '看谁会开机自启，能禁能开',
          icon: Icons.rocket_launch_outlined,
          onTap: () => _push(const AutostartPage()),
        ),
        _Tool(
          title: '系统设置',
          subtitle: '直接打开电视的系统设置',
          icon: Icons.settings_suggest_outlined,
          onTap: _openSystemSettings,
        ),
        _Tool(
          title: '信号源切换',
          subtitle: '切 HDMI / AV / 电视（只有电视机型有）',
          icon: Icons.input_rounded,
          onTap: _openInputSource,
        ),
      ];

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// 打开系统设置。v1.6 起原生侧会返回"到底从哪个入口进去的"，
  /// 一个都没进去时弹窗说明（以前只弹一句"打不开"，等于死路）。
  Future<void> _openSystemSettings() async {
    final hit = await SystemChannel.openSystemSettings();
    if (!mounted) return;
    if (hit.isEmpty) {
      await _explain(
        title: '没能直接打开系统设置',
        body: '这台电视的「设置」不接受标准的系统调用（国产 ROM 常见），'
            '已经帮你打开了本应用的详情页。\n\n'
            '可以这样进设置：\n'
            '1. 回到电视桌面，找齿轮图标的「设置」；\n'
            '2. 有的机型在遥控器上有单独的「设置」键。',
      );
      return;
    }
    _toast('已打开系统设置（$hit），按返回键回到这里');
  }

  /// 打开信号源切换。
  Future<void> _openInputSource() async {
    final inputs = await SystemChannel.tvInputs();
    if (!mounted) return;
    final hit = await SystemChannel.openInputSource();
    if (!mounted) return;

    if (hit.startsWith('input:')) {
      _toast('已打开信号源界面');
      return;
    }
    if (hit == 'settings') {
      await _explain(
        title: '没找到独立的信号源界面',
        body: '这台设备没有提供"信号源切换"的独立入口，已经打开系统设置，'
            '在里面找「信号源 / 输入源 / HDMI」那一项。\n\n'
            '也可以直接按遥控器上的「信号源 / TV / INPUT」键。',
      );
      return;
    }
    await _explain(
      title: '这台设备可能没有信号源',
      body: inputs.isEmpty
          ? '系统里没有登记任何电视输入（手机、平板和普通盒子都没有 HDMI 输入），'
              '所以没有可切换的信号源。\n\n如果你确实在电视上看到这个按钮，'
              '请用遥控器上的「信号源 / TV / INPUT」键。'
          : '系统里登记了 ${inputs.length} 个信号源：\n'
              '${inputs.map((e) => '· ${e.label}').join('\n')}\n\n'
              '但没找到可以跳转的切换界面，请用遥控器上的「信号源 / TV / INPUT」键。',
    );
  }

  Future<void> _explain({required String title, required String body}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: Text(title),
        content: Text(body,
            style: const TextStyle(fontSize: 13.5, height: 1.7)),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ------------------------------------------------------------- 按键

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final n = _tools.length;

    if (isUp(e)) {
      _move(_index - _cols, n);
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      _move(_index + _cols, n);
      return KeyEventResult.handled;
    }
    if (isLeft(e)) {
      // 第一列再往左 = 回左侧菜单（电视上的习惯）；手机上不显示侧栏，
      // onRequestMenu 会被 Shell 忽略掉，不会出事
      if (_index % _cols == 0) {
        widget.onRequestMenu();
      } else {
        _move(_index - 1, n);
      }
      return KeyEventResult.handled;
    }
    if (isRight(e)) {
      _move(_index + 1, n);
      return KeyEventResult.handled;
    }
    if (isSelect(e)) {
      _tools[clampInt(_index, 0, n - 1)].onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int v, int n) {
    if (v < 0 || v >= n) return;
    if (v == _index) return;
    setState(() => _index = v);
  }

  // ------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final compact = isCompact(context);
    final tools = _tools;

    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                pagePad(context), compact ? 10 : 20, pagePad(context), 4),
            child: const PanelTitle('工具'),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                pagePad(context), 0, pagePad(context), compact ? 8 : 14),
            child: Text(
              '下载、文件、应用、内存 —— 都不影响服务器上的原文件。',
              style: TextStyle(
                fontSize: compact ? 12.5 : 14,
                height: 1.5,
                color: TvColors.textDim,
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                // 列数：够宽就 4 列，普通电视 3 列，窄屏 2 列
                final cols =
                    c.maxWidth >= 1180 ? 4 : (c.maxWidth >= 820 ? 3 : 2);
                _cols = cols;
                final ratio = c.maxWidth >= 820 ? 1.55 : 1.35;

                return GridView.builder(
                  padding: EdgeInsets.fromLTRB(
                      pagePad(context), 4, pagePad(context), 18),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: ratio,
                  ),
                  itemCount: tools.length,
                  itemBuilder: (context, i) => _ToolCard(
                    tool: tools[i],
                    focused: widget.focusNode.hasFocus && i == _index,
                    compact: compact,
                    onTap: () {
                      setState(() => _index = i);
                      widget.focusNode.requestFocus();
                      tools[i].onTap();
                    },
                  ),
                );
              },
            ),
          ),
          const StatusBar(text: ''),
        ],
      ),
    );
  }
}

class _Tool {
  const _Tool({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.tool,
    required this.focused,
    required this.compact,
    required this.onTap,
  });

  final _Tool tool;
  final bool focused;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FocusFrame(
      focused: focused,
      radius: 14,
      color: TvColors.card,
      onTap: onTap,
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: compact ? 34 : 40,
            height: compact ? 34 : 40,
            decoration: BoxDecoration(
              color:
                  focused ? alpha(TvColors.accent, 0.22) : TvColors.cardActive,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(tool.icon,
                size: compact ? 20 : 23,
                color: focused ? TvColors.focus : TvColors.accent),
          ),
          const SizedBox(height: 10),
          Text(
            tool.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 15 : 17,
              fontWeight: FontWeight.w700,
              color: TvColors.text,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Text(
              tool.subtitle,
              maxLines: compact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 11.5 : 12.5,
                height: 1.4,
                color: TvColors.textDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
