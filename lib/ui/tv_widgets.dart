import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/theme.dart';

/// 焦点框。整个 App 的"光标"就靠它 —— 电视上没有鼠标，
/// 用户唯一的空间感来源就是这块高亮描边。
///
/// v1.6 去掉了 AnimatedScale / AnimatedContainer：
///   低端电视盒子上 GPU 很弱，每按一下方向键都要对整块卡片做一次
///   120ms 的缩放+颜色补间，掉帧非常明显（用户反馈"菜单切换很卡"）。
///   现在改成"立刻切"——遥控器的操作反馈本来就该是即时的，
///   电视系统自己的焦点框也都没有渐变。
class FocusFrame extends StatelessWidget {
  const FocusFrame({
    super.key,
    required this.focused,
    required this.child,
    this.radius = 12,
    this.onTap,
    this.padding = EdgeInsets.zero,
    this.color,
  });

  final bool focused;
  final Widget child;
  final double radius;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? (focused ? TvColors.cardActive : Colors.transparent),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: focused ? TvColors.focus : Colors.transparent,
          width: 3,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: alpha(TvColors.focus, 0.28),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          child: child,
        ),
      ),
    );
  }
}

/// 面板里的一行可选中项目（设置项、账户、工具按钮都用它）
class TvRow extends StatelessWidget {
  const TvRow({
    super.key,
    required this.focused,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.height = 66,
    this.danger = false,
  });

  final bool focused;
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double height;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    // 手机上内容区窄，字号缩一档、内边距收一收，否则标题和右侧文字会撞车
    final compact = isCompact(context);
    final pad = compact
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 10);
    final inner = height - (compact ? 16 : 20);

    return FocusFrame(
      focused: focused,
      onTap: onTap,
      padding: pad,
      child: SizedBox(
        height: inner,
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              SizedBox(width: compact ? 10 : 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 16.5 : 19,
                      fontWeight: FontWeight.w600,
                      color: danger ? TvColors.danger : TvColors.text,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    SizedBox(height: compact ? 2 : 4),
                    Text(
                      subtitle!,
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 12.5 : 14,
                        height: 1.35,
                        color: TvColors.textDim,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              SizedBox(width: compact ? 8 : 12),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 页面顶部标题条（工具里的几个子页面、扫码页共用）。
///
/// 电视上：一行排开，标题 24 + 右边一长串说明。
/// 手机上：标题缩到 19，说明文字挪到第二行 —— 360dp 的屏幕上
/// "返回键 + 标题 + 说明 + 按钮"硬塞一行一定会溢出，溢出就是"显示不全"。
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final compact = isCompact(context);
    final pad = EdgeInsets.fromLTRB(
      compact ? 8 : 22,
      compact ? 6 : 14,
      compact ? 8 : 22,
      compact ? 2 : 8,
    );

    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: compact ? 19 : 24,
        fontWeight: FontWeight.w700,
      ),
    );

    if (compact) {
      return Padding(
        padding: pad,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (leading != null) leading!,
                Expanded(child: titleText),
                ...actions,
              ],
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  left: leading == null ? 2 : 46,
                  right: 4,
                  top: 2,
                ),
                child: Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: TvColors.textDim),
                ),
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: pad,
      child: Row(
        children: [
          if (leading != null) leading!,
          Flexible(flex: 3, child: titleText),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(width: 14),
            Flexible(
              flex: 4,
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: TvColors.textDim),
              ),
            ),
          ],
          ...actions,
        ],
      ),
    );
  }
}

/// 面板标题（"账户" / "设置" ...）
class PanelTitle extends StatelessWidget {
  const PanelTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final compact = isCompact(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 4 : 8, 0, compact ? 4 : 8,
          compact ? 10 : 18),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 21 : 26,
                fontWeight: FontWeight.w700,
                color: TvColors.text,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 分组小标题
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: TvColors.textDim,
          ),
        ),
      );
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key, this.icon = Icons.inbox_outlined});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: alpha(TvColors.textDim, 0.5)),
            const SizedBox(height: 16),
            Text(text, style: const TextStyle(fontSize: 18, color: TvColors.textDim)),
            const SizedBox(height: 10),
            const Text(
              '按「返回」回到菜单，或换一个文件夹试试',
              style: TextStyle(fontSize: 14, color: TvColors.textDim),
            ),
          ],
        ),
      );
}

class ErrorBox extends StatelessWidget {
  const ErrorBox({super.key, required this.message, this.onRetry, this.focused = true});

  final String message;
  final VoidCallback? onRetry;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: FocusFrame(
          focused: focused,
          color: alpha(TvColors.danger, 0.08),
          onTap: onRetry,
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 52, color: TvColors.danger),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, height: 1.5, color: TvColors.text),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 18),
                Text(
                  focused ? '按「OK」重试' : '重试',
                  style: const TextStyle(fontSize: 15, color: TvColors.focus),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部状态条
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.text, this.warn = false});

  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox(height: 34);
    final compact = isCompact(context);
    return Container(
      height: compact ? 26 : 34,
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 20),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(
            warn ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 15,
            color: warn ? TvColors.danger : TvColors.textDim,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 12 : 13,
                color: warn ? TvColors.danger : TvColors.textDim,
              ),
            ),
          ),
          // 遥控器提示只对电视有意义，手机上纯占地方
          if (!compact)
            const Text(
              '遥控：方向键移动 · OK 打开 · 返回键上一级 · 菜单键刷新',
              style: TextStyle(fontSize: 12, color: TvColors.textDim),
            ),
        ],
      ),
    );
  }
}
