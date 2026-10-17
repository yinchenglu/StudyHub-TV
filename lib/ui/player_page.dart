import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/fmt.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'keys.dart';

/// 全屏播放器（视频 / 音乐共用）。
///
/// 遥控器：
///   ← →  快退 / 快进 10 秒
///   ↑ ↓  音量
///   OK   暂停 / 继续
///   返回  退出
///
/// 为什么自己画控制条，不用 media_kit 自带的：
///   自带的按钮是给小屏触屏设计的，3 米外看不清、遥控也对不上焦。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.app,
    required this.files,
    required this.initial,
  });

  final AppState app;
  final List<RemoteEntry> files;
  final int initial;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _vc;
  late int _index;

  final List<StreamSubscription> _subs = [];

  bool _ui = true;
  bool _playing = false;
  bool _buffering = true;
  int _volume = 100;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  String? _error;
  Timer? _hideTimer;

  RemoteEntry get _cur => widget.files[_index];
  bool get _isVideo => _cur.kind == MediaKind.video;

  @override
  void initState() {
    super.initState();
    _index = widget.initial < 0
        ? 0
        : (widget.initial >= widget.files.length ? widget.files.length - 1 : widget.initial);

    _player = Player();
    _vc = VideoController(_player);

    _subs.add(_player.stream.position.listen((p) {
      if (mounted) setState(() => _pos = p);
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (mounted) setState(() => _dur = d);
    }));
    _subs.add(_player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    }));
    _subs.add(_player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    }));
    _subs.add(_player.stream.completed.listen((v) {
      if (v) _onCompleted();
    }));
    _subs.add(_player.stream.error.listen((e) {
      if (mounted && e.isNotEmpty) setState(() => _error = e);
    }));

    _open();
    _scheduleHide();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 播放

  Future<void> _open() async {
    setState(() {
      _error = null;
      _pos = Duration.zero;
      _dur = Duration.zero;
      _buffering = true;
    });
    try {
      final ref = widget.app.ref(_cur.path);
      await _player.open(
        Media(ref.url, httpHeaders: ref.headers.isEmpty ? null : ref.headers),
      );
      await _player.setVolume(_volume.toDouble());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onCompleted() {
    if (!widget.app.store.autoNext) {
      if (mounted) setState(() => _ui = true);
      return;
    }
    if (_index + 1 < widget.files.length) {
      _next();
    } else if (mounted) {
      setState(() => _ui = true);
    }
  }

  void _next() {
    if (_index + 1 >= widget.files.length) return;
    setState(() => _index++);
    _open();
  }

  void _prev() {
    if (_index <= 0) return;
    setState(() => _index--);
    _open();
  }

  Future<void> _seekBy(int seconds) async {
    var target = _pos + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (_dur > Duration.zero && target > _dur) target = _dur;
    await _player.seek(target);
    setState(() => _pos = target);
  }

  Future<void> _seekToFraction(double f) async {
    if (_dur <= Duration.zero) return;
    var v = f;
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    final target = Duration(milliseconds: (v * _dur.inMilliseconds).round());
    await _player.seek(target);
    setState(() => _pos = target);
  }

  Future<void> _togglePlay() async {
    await _player.playOrPause();
    _scheduleHide();
  }

  Future<void> _volumeBy(int d) async {
    _volume = clampInt(_volume + d, 0, 100);
    await _player.setVolume(_volume.toDouble());
    if (mounted) setState(() {});
    _scheduleHide();
  }

  // ------------------------------------------------------------- UI 显隐

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_ui) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _ui = false);
    });
  }

  void _showUi() {
    if (!_ui) setState(() => _ui = true);
    _scheduleHide();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    _showUi();

    if (isLeft(e)) {
      _seekBy(-10);
      return KeyEventResult.handled;
    }
    if (isRight(e)) {
      _seekBy(10);
      return KeyEventResult.handled;
    }
    if (isUp(e)) {
      _volumeBy(5);
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      _volumeBy(-5);
      return KeyEventResult.handled;
    }
    if (isSelect(e) || isPlayPause(e)) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (isMenu(e)) {
      setState(() => _ui = !_ui);
      _scheduleHide();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------- 渲染

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_ui) {
              setState(() => _ui = false);
              _hideTimer?.cancel();
            } else {
              _showUi();
            }
          },
          child: Stack(
            children: [
              Positioned.fill(child: _surface()),
              if (_buffering && _error == null) const Center(
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(strokeWidth: 2.8),
                ),
              ),
              if (_error != null) _errorLayer(),
              if (!_playing && !_buffering && _error == null)
                const Center(
                  child: Icon(Icons.play_circle_fill,
                      size: 88, color: Colors.white24),
                ),
              _topBar(),
              _bottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _surface() {
    if (_error != null) return const ColoredBox(color: Colors.black);
    if (!_isVideo) {
      // 音乐：不放 Video 组件，铺一层静态背景就行
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0E1620), Color(0xFF060A0E)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.album_rounded, size: 120, color: TvColors.accent),
              const SizedBox(height: 22),
              Text(
                stemOf(_cur.name),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      );
    }
    return Video(
      controller: _vc,
      controls: NoVideoControls,
      fit: BoxFit.contain,
      fill: Colors.black,
    );
  }

  Widget _errorLayer() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Container(
            padding: const EdgeInsets.all(26),
            decoration: BoxDecoration(
              color: alpha(TvColors.danger, 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: alpha(TvColors.danger, 0.4)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 46, color: TvColors.danger),
                const SizedBox(height: 14),
                Text(
                  '播放失败\n$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, height: 1.6),
                ),
                const SizedBox(height: 8),
                const Text(
                  '常见原因：格式不被支持 / 服务器不支持 Range / 网络断了',
                  style: TextStyle(fontSize: 13, color: TvColors.textDim),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _topBar() => AnimatedPositioned(
        duration: const Duration(milliseconds: 180),
        top: _ui ? 0 : -100,
        left: 0,
        right: 0,
        child: Container(
          height: 96,
          padding: const EdgeInsets.fromLTRB(26, 20, 16, 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [alpha(Colors.black, 0.8), Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _cur.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_index + 1} / ${widget.files.length}'
                      '${_isVideo ? '' : ' · 音频'}'
                      ' · 音量 $_volume%',
                      style: const TextStyle(
                          fontSize: 12.5, color: TvColors.textDim),
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
      );

  Widget _bottomBar() => AnimatedPositioned(
        duration: const Duration(milliseconds: 180),
        bottom: _ui ? 0 : -170,
        left: 0,
        right: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 22),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [alpha(Colors.black, 0.88), Colors.transparent],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ProgressBar(
                pos: _pos,
                dur: _dur,
                onSeek: _seekToFraction,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(fmtDuration(_pos),
                      style: const TextStyle(
                          fontSize: 13, color: TvColors.textDim)),
                  const Text(' / ',
                      style: TextStyle(fontSize: 13, color: TvColors.textDim)),
                  Text(fmtDuration(_dur),
                      style: const TextStyle(
                          fontSize: 13, color: TvColors.textDim)),
                  const Spacer(),
                  _CtlBtn(
                    icon: Icons.skip_previous_rounded,
                    onTap: _index > 0 ? _prev : null,
                  ),
                  _CtlBtn(
                    icon: Icons.replay_10_rounded,
                    onTap: () => _seekBy(-10),
                  ),
                  _CtlBtn(
                    icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    big: true,
                    onTap: _togglePlay,
                  ),
                  _CtlBtn(
                    icon: Icons.forward_10_rounded,
                    onTap: () => _seekBy(10),
                  ),
                  _CtlBtn(
                    icon: Icons.skip_next_rounded,
                    onTap: _index + 1 < widget.files.length ? _next : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

/// 进度条：触摸可点可拖；遥控靠左右键（不抢焦点，避免和其它按键打架）。
/// 用 CustomPaint 画 —— Stack + FractionallySizedBox 在 loose 约束下尺寸不可靠。
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.pos, required this.dur, required this.onSeek});

  final Duration pos;
  final Duration dur;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final total = dur.inMilliseconds;
    var frac = total <= 0 ? 0.0 : pos.inMilliseconds / total;
    if (frac < 0) frac = 0;
    if (frac > 1) frac = 1;

    return LayoutBuilder(
      builder: (context, c) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => onSeek(d.localPosition.dx / c.maxWidth),
        onHorizontalDragUpdate: (d) => onSeek(d.localPosition.dx / c.maxWidth),
        child: SizedBox(
          width: c.maxWidth,
          height: 26,
          child: CustomPaint(painter: _BarPainter(frac)),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  const _BarPainter(this.frac);

  final double frac;

  @override
  void paint(Canvas canvas, Size size) {
    const radius = Radius.circular(3);
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, size.height / 2 - 3, size.width, 6),
      radius,
    );
    canvas.drawRRect(track, Paint()..color = Colors.white24);

    if (frac > 0) {
      final fill = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, size.height / 2 - 3, size.width * frac, 6),
        radius,
      );
      canvas.drawRRect(fill, Paint()..color = TvColors.accent);
    }

    canvas.drawCircle(
      Offset(size.width * frac, size.height / 2),
      7,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _BarPainter oldDelegate) =>
      oldDelegate.frac != frac;
}

class _CtlBtn extends StatelessWidget {
  const _CtlBtn({required this.icon, this.onTap, this.big = false});

  final IconData icon;
  final VoidCallback? onTap;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final size = big ? 62.0 : 48.0;
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(40),
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: big ? alpha(TvColors.accent, 0.90) : alpha(Colors.white, 0.10),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: big ? 34 : 25,
            color: enabled
                ? (big ? const Color(0xFF06222B) : Colors.white)
                : Colors.white24,
          ),
        ),
      ),
    );
  }
}
