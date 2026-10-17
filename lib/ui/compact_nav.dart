import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models.dart';

/// 手机 / 窄屏用的底部导航条。
///
/// 为什么不是侧栏收窄一点：6 个中文菜单项 + 图标，最窄也要 150dp，
/// 在 360dp 的手机上等于把内容区砍掉四成；而且手指够不到屏幕左上角。
/// 底部一条横排图标是手机上最省地方、最好按的做法。
///
/// 不需要焦点：手机是触摸操作，点哪个就是哪个。
/// 电视那条路径完全不经过这里（宽屏走 Sidebar），所以遥控逻辑零影响。
class CompactNav extends StatelessWidget {
  const CompactNav({
    super.key,
    required this.items,
    required this.current,
    required this.onTap,
  });

  final List<Section> items;
  final Section current;
  final ValueChanged<int> onTap;

  static const double _h = 58;

  @override
  Widget build(BuildContext context) {
    // 有手势条的机器（全面屏）要把底部安全区让出来，否则按钮压在条上
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      decoration: const BoxDecoration(
        color: TvColors.panel,
        border: Border(top: BorderSide(color: TvColors.divider)),
      ),
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: _h,
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: _NavItem(
                  section: items[i],
                  selected: items[i] == current,
                  onTap: () => onTap(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final Section section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? TvColors.accent : TvColors.textDim;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        // 手机上水波纹有必要（告诉用户"我按到了"），电视那边才关掉
        splashColor: alpha(TvColors.accent, 0.14),
        highlightColor: alpha(TvColors.accent, 0.08),
        child: Stack(
          children: [
            if (selected)
              Positioned(
                top: 0,
                left: 12,
                right: 12,
                child: Container(
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: TvColors.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(section.icon, size: 21, color: color),
                  const SizedBox(height: 3),
                  Text(
                    section.label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
