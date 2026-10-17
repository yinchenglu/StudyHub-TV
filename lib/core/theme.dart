import 'package:flutter/material.dart';

/// 电视端主题：深色底 + 高对比 + 大字号。
///
/// 为什么必须深色：电视晚上看，白底会晃眼；而且绝大多数电视盒子
/// 的默认桌面就是深色，白底 App 切过去像"进错了程序"。
///
/// 为什么字要大：3 米外看 55 寸，10pt 的字基本等于看不见。
/// 这里所有字号都在 14 以上，标题 22，选中项 20。
class TvColors {
  /// 最底层背景（几乎纯黑，OLED 上省电也不刺眼）
  static const bg = Color(0xFF0B0F14);

  /// 左侧菜单 / 顶栏（比背景亮一点，形成分区）
  static const panel = Color(0xFF141A21);

  /// 卡片底色
  static const card = Color(0xFF1B232C);

  /// 卡片悬停/选中底色
  static const cardActive = Color(0xFF243040);

  /// 主强调色（青绿，跟 StudyHub 的蓝绿体系一致）
  static const accent = Color(0xFF28C8A8);

  /// 焦点描边（选中项外圈）
  static const focus = Color(0xFF3FE0C0);

  static const text = Color(0xFFF2F5F7);
  static const textDim = Color(0xFF9AA7B4);
  static const danger = Color(0xFFFF6B6B);
  static const divider = Color(0xFF28313C);
}

class AppTheme {
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: TvColors.bg,
      canvasColor: TvColors.bg,
      colorScheme: base.colorScheme.copyWith(
        primary: TvColors.accent,
        secondary: TvColors.accent,
        surface: TvColors.panel,
        onSurface: TvColors.text,
      ),
      dividerColor: TvColors.divider,
      splashFactory: NoSplash.splashFactory, // 电视上水波纹很脏，去掉
      textTheme: base.textTheme.apply(
        bodyColor: TvColors.text,
        displayColor: TvColors.text,
      ),
      // 输入框（登录页用）：电视上没有鼠标，边框要够明显
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: TvColors.card,
        labelStyle: const TextStyle(color: TvColors.textDim, fontSize: 15),
        hintStyle: const TextStyle(color: TvColors.textDim, fontSize: 15),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TvColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TvColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TvColors.focus, width: 2),
        ),
      ),
    );
  }
}

/// 半透明叠加色。Flutter 3.27 起 withOpacity 被标记废弃，统一走这个。
Color alpha(Color c, double a) => c.withValues(alpha: a);
