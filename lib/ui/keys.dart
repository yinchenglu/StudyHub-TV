import 'package:flutter/services.dart';

/// 遥控器按键判定。
///
/// 安卓电视遥控 / 蓝牙遥控最终都会被翻译成这几个逻辑键：
///   方向键 → arrowUp/Down/Left/Right
///   OK / 确定 → select（部分遥控发的是 enter，游戏手柄发 gameButtonA）
///   菜单键 → contextMenu
///   返回键 → 不走这里，由系统当作"返回"交给 PopScope 处理
///
/// 保留 KeyRepeatEvent：长按方向键连续移动是电视上的基本预期，
/// 只认 KeyDownEvent 的话按住不动只走一格，用户会以为卡了。
bool isUp(KeyEvent e) => e.logicalKey == LogicalKeyboardKey.arrowUp;
bool isDown(KeyEvent e) => e.logicalKey == LogicalKeyboardKey.arrowDown;
bool isLeft(KeyEvent e) => e.logicalKey == LogicalKeyboardKey.arrowLeft;
bool isRight(KeyEvent e) => e.logicalKey == LogicalKeyboardKey.arrowRight;

bool isSelect(KeyEvent e) {
  final k = e.logicalKey;
  return k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.space ||
      k == LogicalKeyboardKey.gameButtonA;
}

/// 菜单键 / F1 / R —— 统一当"刷新"用
bool isMenu(KeyEvent e) {
  final k = e.logicalKey;
  return k == LogicalKeyboardKey.contextMenu ||
      k == LogicalKeyboardKey.f1 ||
      k == LogicalKeyboardKey.keyR;
}

/// 播放器里的多媒体键（部分遥控有）
bool isPlayPause(KeyEvent e) {
  final k = e.logicalKey;
  return k == LogicalKeyboardKey.mediaPlayPause ||
      k == LogicalKeyboardKey.mediaPlay ||
      k == LogicalKeyboardKey.mediaPause;
}
