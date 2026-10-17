import 'package:flutter/widgets.dart';

/// 窄屏断点（逻辑像素）。
///
/// 为什么是 720：
///   * 电视 / 平板横屏几乎没有低于 960 的，进不了这个分支，电视布局一点不变；
///   * 手机竖屏 360~430、小屏手机横屏 640~740 —— 这些尺寸下
///     "左侧 246dp 固定菜单 + 右侧内容" 会把内容区压成一条 100dp 的竖条，
///     就是我们看到的"显示不全、点不到按钮"。
///
/// 所以窄屏统一换成：底部导航 + 内容区占满宽度。
const double kCompactWidth = 720;

/// 当前窗口是不是窄屏（手机）
bool isCompact(BuildContext context) =>
    MediaQuery.sizeOf(context).width < kCompactWidth;

/// 按宽度在"电视值 / 手机值"之间取值，省得到处写三元表达式
double byWidth(BuildContext context, {required double wide, required double compact}) =>
    isCompact(context) ? compact : wide;

/// 页面左右内边距：电视 22，手机 12
double pagePad(BuildContext context) => byWidth(context, wide: 22, compact: 12);
