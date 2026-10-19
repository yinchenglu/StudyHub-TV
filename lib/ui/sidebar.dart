import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'tv_widgets.dart';

/// 左侧主菜单（Kodi 那种布局）。
///
/// 焦点模型说明：整条菜单只占**一个** Focus 节点，上下键由自己算 index，
/// 不用 Flutter 默认的焦点遍历。原因：
///   * 电视上默认遍历遇到 GridView 经常跳得莫名其妙（尤其跨滚动区域）；
///   * 自己算 index 可以精确控制"最后一屏"的行为，也能顺手做边缘回绕。
///
/// v1.5 起改成按**可用高度**自适应：
///   强制横屏后，手机上只有 360dp 高、480p 的老电视也只有 400dp 左右，
///   原来固定 48dp × 6 项 + 头部 + 账号卡 + 版本号 ≈ 500dp，
///   必然有一两项被挤到屏幕外（用户反馈的"菜单溢出"）。
///   现在行高会随手缩，并且菜单区可滚动 + 跟随焦点自动滚 —— 不管多矮，
///   每一项都够得着。
class Sidebar extends StatefulWidget {
  const Sidebar({
    super.key,
    required this.app,
    required this.focusNode,
    required this.items,
    required this.index,
    required this.onKey,
    required this.onTap,
    required this.onAccount,
    this.width = 246,
  });

  final AppState app;
  final FocusNode focusNode;
  final List<Section> items;
  final int index;
  final KeyEventResult Function(FocusNode node, KeyEvent event) onKey;
  final ValueChanged<int> onTap;
  final VoidCallback onAccount;
  final double width;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final ScrollController _scroll = ScrollController();

  /// 当前这一帧用的行槽高度（行高 + 上下留白），滚动定位要用
  double _slot = 52;

  @override
  void didUpdateWidget(Sidebar old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _reveal(widget.index);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 把第 [i] 项滚进可视区
  void _reveal(int i) {
    if (!_scroll.hasClients || widget.items.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final top = i * _slot;
      final vp = _scroll.position.viewportDimension;
      final cur = _scroll.offset;
      if (top < cur) {
        _scroll.animateTo(top,
            duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
      } else if (top + _slot > cur + vp) {
        _scroll.animateTo(top + _slot - vp,
            duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final acc = app.account;
    final h = MediaQuery.sizeOf(context).height;

    // 三档密度：正常 / 矮屏 / 极矮（手机横屏 360dp 就是极矮）
    final tight = h < 560;
    final tiny = h < 430;
    _slot = tiny ? 42 : (tight ? 46 : 52);

    return Container(
      width: widget.width,
      decoration: const BoxDecoration(
        color: TvColors.panel,
        border: Border(right: BorderSide(color: TvColors.divider)),
      ),
      child: Focus(
        focusNode: widget.focusNode,
        onKeyEvent: widget.onKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---------------- 顶部标识 ----------------
            Padding(
              padding: EdgeInsets.fromLTRB(16, tiny ? 8 : (tight ? 12 : 22), 16,
                  tiny ? 2 : 6),
              child: Row(
                children: [
                  Container(
                    width: tiny ? 24 : 32,
                    height: tiny ? 24 : 32,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      gradient: const LinearGradient(
                        colors: [TvColors.accent, Color(0xFF1E8FA8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Icon(Icons.play_arrow_rounded,
                        color: const Color(0xFF06222B), size: tiny ? 18 : 24),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'StudyHub',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: tiny ? 16 : 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  if (!tiny)
                    const Text('TV',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: TvColors.accent,
                        )),
                ],
              ),
            ),

            // ---------------- 当前账号 ----------------
            // 只在已经有账号时显示：没有账号时这里原本写着「未添加账号」，
            // 但「账户」本来就是菜单第一项，再挂一个"去添加"的入口
            // 等于同一件事摆两遍，还占掉了最上面的位置。
            // 屏幕太矮时整块收掉 —— 账号入口在菜单第一项里仍然有。
            if (acc != null && !tiny)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                child: FocusFrame(
                  focused: false,
                  radius: 10,
                  color: TvColors.card,
                  onTap: widget.onAccount,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(
                    children: [
                      Icon(
                        acc.proto == Proto.smb
                            ? Icons.folder_shared_outlined
                            : Icons.cloud_outlined,
                        size: 17,
                        color: TvColors.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              acc.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (!tight) ...[
                              const SizedBox(height: 2),
                              Text(
                                '${acc.proto.label} · ${app.connected ? '已连接' : '未连接'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: app.connected
                                      ? TvColors.textDim
                                      : TvColors.danger,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            SizedBox(height: tiny ? 2 : 6),

            // ---------------- 菜单 ----------------
            // 可滚动：屏幕再矮也不会把「工具 / 设置」挤到屏幕外；
            // 焦点移动时自动跟随（_reveal），遥控器不会"按到看不见的地方"。
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                itemExtent: _slot,
                itemCount: widget.items.length,
                itemBuilder: (context, i) {
                  final s = widget.items[i];
                  // 分组分割线由 Section.dividerBefore 决定（v1.2：媒体三项 / 系统两项）
                  final needDivider = i > 0 && s.dividerBefore;
                  return Stack(
                    children: [
                      if (needDivider)
                        const Positioned(
                          left: 8,
                          right: 8,
                          top: 0,
                          child: Divider(height: 1, color: TvColors.divider),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: _MenuTile(
                          section: s,
                          selected: app.section == s,
                          focused: widget.focusNode.hasFocus &&
                              widget.index == i,
                          height: _slot - 6,
                          compact: tight,
                          onTap: () => widget.onTap(i),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            // ---------------- 底部版本 ----------------
            if (!tiny)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Text(
                  'v$kAppVersion',
                  style: const TextStyle(fontSize: 11, color: TvColors.textDim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.section,
    required this.selected,
    required this.focused,
    required this.onTap,
    required this.height,
    required this.compact,
  });

  final Section section;
  final bool selected;
  final bool focused;
  final VoidCallback onTap;
  final double height;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = focused || selected ? TvColors.text : TvColors.textDim;
    return FocusFrame(
      focused: focused,
      radius: 10,
      color: selected && !focused ? alpha(TvColors.accent, 0.12) : null,
      onTap: onTap,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            // 选中标记：左边一条竖线
            Container(
              width: 4,
              height: compact ? 18 : 22,
              margin: const EdgeInsets.only(left: 6, right: 10),
              decoration: BoxDecoration(
                color: selected ? TvColors.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Icon(
              section.icon,
              size: compact ? 19 : 21,
              color: focused
                  ? TvColors.focus
                  : (selected ? TvColors.accent : TvColors.textDim),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                section.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 16 : 18,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
