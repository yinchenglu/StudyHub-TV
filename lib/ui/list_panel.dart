import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fmt.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import 'keys.dart';
import 'tv_widgets.dart';

/// 竖排列表里的一项
class TvListItem {
  const TvListItem({
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.trailingText,
    this.danger = false,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final String? subtitle;
  final String? trailingText;
  final bool danger;
}

/// 通用「竖排列表」面板 —— 账户 / 设置 / 工具 三个页面共用。
///
/// 抽出来是因为它们的交互完全一样：上下移动、OK 执行、左键回菜单。
/// 复制三份代码只会让三处的滚动/回绕行为慢慢长歪。
class TvListPanel extends StatefulWidget {
  const TvListPanel({
    super.key,
    required this.title,
    required this.items,
    required this.focusNode,
    required this.onRequestMenu,
    this.subtitle,
    this.footer,
    this.maxWidth = 780,
    this.headerAction,
  });

  final String title;
  final String? subtitle;
  final List<TvListItem> items;
  final FocusNode focusNode;
  final VoidCallback onRequestMenu;
  final Widget? footer;
  final double maxWidth;

  /// 标题右边的小按钮（手机上没有左侧菜单，需要它把"添加账号"之类
  /// 的入口放到一眼能看到、手指够得着的地方）。电视上传 null。
  final Widget? headerAction;

  @override
  State<TvListPanel> createState() => _TvListPanelState();
}

class _TvListPanelState extends State<TvListPanel> {
  int _index = 0;
  double _rowH = 74;
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final n = widget.items.length;

    if (isUp(event)) {
      _move(_index - 1);
      return KeyEventResult.handled;
    }
    if (isDown(event)) {
      _move(_index + 1);
      return KeyEventResult.handled;
    }
    if (isLeft(event)) {
      widget.onRequestMenu();
      return KeyEventResult.handled;
    }
    if (isRight(event)) {
      // 列表是单列的，右键没有下一列，直接当"确认"用更符合直觉
      if (n > 0) widget.items[clampInt(_index, 0, n - 1)].onTap();
      return KeyEventResult.handled;
    }
    if (isSelect(event)) {
      if (n > 0) widget.items[clampInt(_index, 0, n - 1)].onTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int v) {
    final n = widget.items.length;
    if (n == 0) return;
    final next = clampInt(v, 0, n - 1);
    if (next == _index) return;
    setState(() => _index = next);
    if (!_scroll.hasClients) return;
    final top = next * _rowH;
    final viewport = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.animateTo(top,
          duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
    } else if (top + _rowH > _scroll.offset + viewport) {
      _scroll.animateTo(top + _rowH - viewport,
          duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.items.length;
    if (n > 0 && _index >= n) _index = n - 1;

    // 手机上的行高稍微收一点，但保证 ≥ 56dp 的触摸目标
    final compact = isCompact(context);
    _rowH = compact ? 70 : 74;
    final hPad = pagePad(context);

    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(hPad, compact ? 10 : 20, hPad, 6),
            child: PanelTitle(widget.title, trailing: widget.headerAction),
          ),
          if (widget.subtitle != null)
            Padding(
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, compact ? 8 : 14),
              child: Text(
                widget.subtitle!,
                style: TextStyle(
                  fontSize: compact ? 12.5 : 14,
                  height: 1.5,
                  color: TvColors.textDim,
                ),
              ),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.maxWidth),
                child: ListView.builder(
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(
                      compact ? 10 : 24, 4, compact ? 10 : 24, 16),
                  itemCount: widget.items.length + 1,
                  itemBuilder: (context, i) {
                    if (i == widget.items.length) {
                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                            compact ? 6 : 16, 18, compact ? 6 : 16, 8),
                        child: widget.footer ?? const SizedBox.shrink(),
                      );
                    }
                    final it = widget.items[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: SizedBox(
                        height: _rowH - 6,
                        child: TvRow(
                          height: _rowH - 6,
                          focused: widget.focusNode.hasFocus && i == _index,
                          title: it.title,
                          subtitle: it.subtitle,
                          danger: it.danger,
                          leading: Icon(
                            it.icon,
                            size: 22,
                            color: it.danger ? TvColors.danger : TvColors.textDim,
                          ),
                          trailing: it.trailingText == null
                              ? null
                              : Text(
                                  it.trailingText!,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: TvColors.accent,
                                  ),
                                ),
                          onTap: () {
                            setState(() => _index = i);
                            widget.focusNode.requestFocus();
                            it.onTap();
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const StatusBar(text: ''),
        ],
      ),
    );
  }
}
