import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fmt.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'keys.dart';

/// 全屏看图。
///
/// 遥控器：
///   左右   上一张 / 下一张
///   OK     显隐顶部信息条
///   菜单   弹出设置面板（自动播放间隔 / 关闭）
///   返回   退出
///
/// v1.6 的两处改动（用户要求）：
///   1. **去掉左右两边的箭头按钮** —— 电视上没有鼠标，箭头纯占画面，
///      还容易让人以为是"当前焦点"。切图本来就是左右键的事。
///   2. **自动播放收进菜单键弹出的面板** —— 以前是右上角一个小图标，
///      遥控器根本对不上焦，等于没法用。现在按菜单键 → 选间隔 → OK。
///
/// 没有做双指缩放（V1 取舍）：电视上没人用手指放大，
/// 遥控器也没有对应的键；要放大等 V2 加"OK 键切换 1x/2x"更靠谱。
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.app,
    required this.files,
    required this.initial,
  });

  final AppState app;
  final List<RemoteEntry> files;
  final int initial;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pc;
  late int _index;
  bool _bar = true;
  Timer? _hideTimer;
  Timer? _slideTimer;

  /// 菜单面板是否打开
  bool _menu = false;
  int _menuIndex = 0;

  /// 菜单里可选的自动播放间隔（0 = 关闭）。默认关（用户要求）。
  static const List<int> _steps = [0, 3, 5, 10, 20, 30, 60];

  @override
  void initState() {
    super.initState();
    _index = clampInt(widget.initial, 0, widget.files.isEmpty ? 0 : widget.files.length - 1);
    _pc = PageController(initialPage: _index);
    _restartSlide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _slideTimer?.cancel();
    _pc.dispose();
    super.dispose();
  }

  int get _slideSec => widget.app.store.slideshowSec;

  /// 自动播放（电子相框模式）。设置里改成 0 就不会启动。
  void _restartSlide() {
    _slideTimer?.cancel();
    final sec = _slideSec;
    if (sec <= 0 || widget.files.length < 2) return;
    _slideTimer = Timer.periodic(Duration(seconds: sec), (_) {
      if (!mounted) return;
      _go(_index + 1, wrap: true);
    });
  }

  void _go(int i, {bool wrap = false}) {
    if (widget.files.isEmpty) return;
    var next = i;
    if (wrap) {
      next = i % widget.files.length;
    } else {
      if (i < 0 || i >= widget.files.length) return;
    }
    setState(() => _index = next);
    _pc.jumpToPage(next);
    _restartSlide();
  }

  Future<void> _setSlide(int sec) async {
    await widget.app.updateSetting(() => widget.app.store.setSlideshowSec(sec));
    if (!mounted) return;
    setState(() {});
    _restartSlide();
  }

  void _toggleBar() {
    setState(() => _bar = !_bar);
    _hideTimer?.cancel();
    if (_bar) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _bar = false);
      });
    }
  }

  void _openMenu() {
    setState(() {
      _menu = true;
      _menuIndex = _steps.indexOf(_slideSec) < 0 ? 0 : _steps.indexOf(_slideSec);
      _bar = true;
    });
    _hideTimer?.cancel();
  }

  void _closeMenu() {
    setState(() => _menu = false);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;

    if (_menu) return _onMenuKey(e);

    if (isLeft(e)) {
      _go(_index - 1);
      return KeyEventResult.handled;
    }
    if (isRight(e)) {
      _go(_index + 1);
      return KeyEventResult.handled;
    }
    if (isUp(e) || isDown(e)) {
      _toggleBar();
      return KeyEventResult.handled;
    }
    if (isSelect(e)) {
      if (!_bar) {
        _toggleBar();
      } else {
        _openMenu();
      }
      return KeyEventResult.handled;
    }
    if (isMenu(e)) {
      _openMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onMenuKey(KeyEvent e) {
    if (isUp(e)) {
      setState(() => _menuIndex =
          clampInt(_menuIndex - 1, 0, _steps.length));
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      setState(() => _menuIndex =
          clampInt(_menuIndex + 1, 0, _steps.length));
      return KeyEventResult.handled;
    }
    if (isSelect(e)) {
      if (_menuIndex >= _steps.length) {
        _closeMenu();
      } else {
        _setSlide(_steps[_menuIndex]);
      }
      return KeyEventResult.handled;
    }
    if (isMenu(e) || isLeft(e) || isRight(e)) {
      _closeMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final files = widget.files;
    if (files.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: Text('没有图片', style: TextStyle(fontSize: 18))),
      );
    }
    final cur = files[_index];

    return PopScope(
      canPop: !_menu,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeMenu();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            children: [
              Positioned.fill(
                child: PageView.builder(
                  controller: _pc,
                  itemCount: files.length,
                  // 手指滑动时不做动画，跟遥控器一致（低端设备更跟手）
                  pageSnapping: true,
                  onPageChanged: (i) {
                    setState(() => _index = i);
                    _restartSlide();
                  },
                  itemBuilder: (context, i) {
                    MediaRef ref;
                    try {
                      ref = widget.app.ref(files[i].path);
                    } catch (_) {
                      return const Center(child: Text('连接已断开'));
                    }
                    return CachedNetworkImage(
                      imageUrl: ref.url,
                      httpHeaders: ref.headers,
                      fit: BoxFit.contain,
                      fadeInDuration: Duration.zero,
                      // 全屏看图不压解码尺寸（要看清细节），
                      // 但磁盘缓存仍然只存原图一份
                      placeholder: (_, __) => const Center(
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(strokeWidth: 2.6),
                        ),
                      ),
                      errorWidget: (_, __, ___) => const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.broken_image_outlined,
                                size: 56, color: Colors.white38),
                            SizedBox(height: 12),
                            Text('这张图打不开',
                                style: TextStyle(color: Colors.white54)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

              // 顶部信息条
              if (_bar)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 92,
                    padding: const EdgeInsets.fromLTRB(26, 18, 20, 10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [alpha(Colors.black, 0.82), Colors.transparent],
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                cur.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${_index + 1} / ${widget.files.length}'
                                '${_slideSec > 0 ? ' · 自动播放 ${_slideSec}s' : ''}'
                                ' · 菜单键 设置',
                                style: const TextStyle(
                                    fontSize: 13, color: TvColors.textDim),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                          iconSize: 26,
                        ),
                      ],
                    ),
                  ),
                ),

              if (_menu) _menuLayer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuLayer() {
    final rows = <Widget>[
      for (var i = 0; i < _steps.length; i++)
        _MenuRow(
          icon: _steps[i] == 0
              ? Icons.stop_circle_outlined
              : Icons.timer_outlined,
          title: _steps[i] == 0 ? '关闭自动播放' : '每 ${_steps[i]} 秒翻一张',
          value: _slideSec == _steps[i] ? '当前' : '',
          focused: _menuIndex == i,
          onTap: () => _setSlide(_steps[i]),
        ),
      _MenuRow(
        icon: Icons.close_rounded,
        title: '关闭面板',
        value: '',
        focused: _menuIndex == _steps.length,
        onTap: _closeMenu,
      ),
    ];

    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: 400,
        padding: const EdgeInsets.fromLTRB(22, 90, 22, 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [alpha(Colors.black, 0.94), alpha(Colors.black, 0.55)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('图片设置',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('↑↓ 选择 · OK 确定 · 菜单/返回 关闭',
                style: TextStyle(fontSize: 12.5, color: TvColors.textDim)),
            const SizedBox(height: 16),
            Expanded(child: ListView(children: rows)),
          ],
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.focused,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: focused ? TvColors.cardActive : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: focused ? TvColors.focus : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 21,
                  color: focused ? TvColors.focus : TvColors.textDim),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              if (value.isNotEmpty)
                Text(value,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: TvColors.accent)),
            ],
          ),
        ),
      ),
    );
  }
}
