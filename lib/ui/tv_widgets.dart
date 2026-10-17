import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 焦点框。整个 App 的"光标"就靠它 —— 电视上没有鼠标，
/// 用户唯一的空间感来源就是这块高亮描边。
///
/// 为什么用 3 点描边 + 轻微放大，而不是 Material 的 InkWell 水波纹：
/// 3 米外看，水波纹根本看不见，而描边 + 放大 3% 一眼就能定位。
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
    return AnimatedScale(
      scale: focused ? 1.03 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
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
    return FocusFrame(
      focused: focused,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: SizedBox(
        height: height - 20,
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 14),
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
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      color: danger ? TvColors.danger : TvColors.text,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: TvColors.textDim),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: TvColors.text,
            ),
          ),
          const Spacer(),
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
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 20),
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
                fontSize: 13,
                color: warn ? TvColors.danger : TvColors.textDim,
              ),
            ),
          ),
          const Text(
            '遥控：方向键移动 · OK 打开 · 返回键上一级 · 菜单键刷新',
            style: TextStyle(fontSize: 12, color: TvColors.textDim),
          ),
        ],
      ),
    );
  }
}
