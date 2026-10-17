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
class Sidebar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final acc = app.account;
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: TvColors.panel,
        border: Border(right: BorderSide(color: TvColors.divider)),
      ),
      child: Focus(
        focusNode: focusNode,
        onKeyEvent: onKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---------------- 顶部标识 ----------------
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      gradient: const LinearGradient(
                        colors: [TvColors.accent, Color(0xFF1E8FA8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Color(0xFF06222B), size: 26),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'StudyHub',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  const Text('TV', style: TextStyle(
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
            if (acc != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                child: FocusFrame(
                  focused: false,
                  radius: 10,
                  color: TvColors.card,
                  onTap: onAccount,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        acc!.proto == Proto.smb
                            ? Icons.folder_shared_outlined
                            : Icons.cloud_outlined,
                        size: 18,
                        color: TvColors.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              acc!.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${acc!.proto.label} · ${app.connected ? '已连接' : '未连接'}',
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
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 6),

            // ---------------- 菜单 ----------------
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                physics: const NeverScrollableScrollPhysics(),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final s = items[i];
                  // 分组分割线由 Section.dividerBefore 决定（v1.2：媒体三项 / 系统两项）
                  final needDivider = i > 0 && s.dividerBefore;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (needDivider)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          child: Divider(height: 1, color: TvColors.divider),
                        ),
                      _MenuTile(
                        section: s,
                        selected: app.section == s,
                        focused: focusNode.hasFocus && index == i,
                        onTap: () => onTap(i),
                      ),
                    ],
                  );
                },
              ),
            ),

            // ---------------- 底部版本 ----------------
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
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
  });

  final Section section;
  final bool selected;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = focused || selected ? TvColors.text : TvColors.textDim;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: FocusFrame(
        focused: focused,
        radius: 10,
        color: selected && !focused ? alpha(TvColors.accent, 0.12) : null,
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              // 选中标记：左边一条竖线
              Container(
                width: 4,
                height: 24,
                margin: const EdgeInsets.only(left: 6, right: 12),
                decoration: BoxDecoration(
                  color: selected ? TvColors.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Icon(
                section.icon,
                size: 21,
                color: focused ? TvColors.focus : (selected ? TvColors.accent : TvColors.textDim),
              ),
              const SizedBox(width: 12),
              Text(
                section.label,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
