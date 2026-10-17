import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/fmt.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'keys.dart';

/// 全屏看图。
///
/// 遥控器：左右切图、OK 显隐信息条、返回退出。
/// 触摸：左右滑动手感由 PageView 自带。
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

  /// 自动播放（电子相框模式）。设置里改成 0 就不会启动。
  void _restartSlide() {
    _slideTimer?.cancel();
    final sec = widget.app.store.slideshowSec;
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
    _pc.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
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

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    if (isLeft(e)) {
      _go(_index - 1);
      return KeyEventResult.handled;
    }
    if (isRight(e)) {
      _go(_index + 1);
      return KeyEventResult.handled;
    }
    if (isSelect(e) || isUp(e) || isDown(e)) {
      _toggleBar();
      return KeyEventResult.handled;
    }
    if (isMenu(e)) {
      _go(_index + 1);
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

    return Scaffold(
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
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              top: _bar ? 0 : -110,
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
                            '${widget.app.store.slideshowSec > 0 ? ' · 自动播放 ${widget.app.store.slideshowSec}s' : ''}',
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

            // 左右切换按钮（触摸用户可见）
            if (files.length > 1) ...[
              Positioned(
                left: 10,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _ArrowBtn(
                    icon: Icons.chevron_left,
                    onTap: () => _go(_index - 1),
                  ),
                ),
              ),
              Positioned(
                right: 10,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _ArrowBtn(
                    icon: Icons.chevron_right,
                    onTap: () => _go(_index + 1),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ArrowBtn extends StatelessWidget {
  const _ArrowBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: 0.55,
        child: InkWell(
          borderRadius: BorderRadius.circular(40),
          onTap: onTap,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: alpha(Colors.black, 0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 34, color: Colors.white),
          ),
        ),
      );
}
