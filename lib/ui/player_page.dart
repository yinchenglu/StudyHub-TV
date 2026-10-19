import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/fmt.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'keys.dart';

/// 全屏播放器（视频 / 音乐共用）。
///
/// 遥控器（没有面板时）：
///   ↑ ↓  上一个 / 下一个视频（v1.6 改，原来是音量）
///   ← →  快退 / 快进 10 秒
///   OK   暂停 / 继续
///   菜单  打开播放面板（目录列表 / 播放模式 / 倍速 / 音量 / 跳过片头片尾）
///   返回  退出
///
/// 播放面板里（v1.6）：
///   播放速度一行：← → 减/加，OK 按 0.5→0.75→…→3→0.5 循环，
///                 长按 OK 直接回 1×。
///   跳过片头/片尾：**按目录生效**。在某个文件夹的某一集上设好，
///                 这个文件夹里所有剧集都跳；换到别的文件夹不跳。
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

/// 当前叠在哪一层上
enum _Layer { none, menu, playlist }

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _vc;
  late int _index;

  final List<StreamSubscription> _subs = [];

  bool _ui = true;
  bool _playing = false;
  bool _buffering = true;
  int _volume = 100;
  Duration _dur = Duration.zero;
  String? _error;
  Timer? _hideTimer;

  /// 播放进度单独放 ValueNotifier。
  ///
  /// 为什么不用 setState：位置流每秒推 10 次左右，setState 会把整页
  /// （含 Video 原生纹理视图、顶部条、两个面板）全部重建一遍，
  /// 在低端电视盒子上就是肉眼可见的卡顿。改成只让进度条和时间文字
  /// 跟着值变，视频画面完全不参与重建。
  final ValueNotifier<Duration> _posN = ValueNotifier(Duration.zero);
  Duration get _pos => _posN.value;

  _Layer _layer = _Layer.none;
  int _menuIndex = 0;
  int _plIndex = 0;
  final ScrollController _plScroll = ScrollController();

  /// 长按 OK 检测（遥控器按住会发 KeyRepeatEvent，只在首次 KeyDown 计时）
  Timer? _holdTimer;
  bool _holdFired = false;

  /// 片尾只触发一次
  bool _endReached = false;

  /// 每次打开新文件 +1，用来作废上一部片子还在跑的"跳片头"循环
  int _openToken = 0;

  /// 当前实际用的解码方式（面板里展示，方便判断卡是不是解码问题）
  String _decoder = '…';

  RemoteEntry get _cur => widget.files[_index];
  bool get _isVideo => _cur.kind == MediaKind.video;

  AppState get app => widget.app;
  PlayMode get _mode => app.store.playMode;
  double get _speed => app.store.speed;

  /// 当前视频所在目录（远端相对路径，去掉文件名）。
  /// 「跳过片头/片尾」按这个 key 存，所以只对本目录的剧集生效。
  String get _dir {
    final p = _cur.path;
    final i = p.lastIndexOf('/');
    return i <= 0 ? '' : p.substring(0, i);
  }

  int get _skipStart => app.store.skipStartOf(_dir);
  int get _skipEnd => app.store.skipEndOf(_dir);

  @override
  void initState() {
    super.initState();
    _index = widget.initial < 0
        ? 0
        : (widget.initial >= widget.files.length
            ? widget.files.length - 1
            : widget.initial);
    _plIndex = _index;

    _player = Player();
    _vc = VideoController(_player);

    _subs.add(_player.stream.position.listen((p) {
      if (!mounted) return;
      _posN.value = p;
      _checkSkipEnd(p);
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
    _holdTimer?.cancel();
    _hideTimer?.cancel();
    _plScroll.dispose();
    _posN.dispose();
    _player.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 播放

  Future<void> _open() async {
    final token = ++_openToken;
    setState(() {
      _error = null;
      _dur = Duration.zero;
      _buffering = true;
      _endReached = false;
    });
    _posN.value = Duration.zero;
    _plIndex = _index;

    try {
      // 解码参数必须在 open 之前设，open 时才会被 mpv 采纳
      await _applyDecodeOptions();

      final ref = app.ref(_cur.path);
      await _player.open(
        Media(ref.url, httpHeaders: ref.headers.isEmpty ? null : ref.headers),
      );
      if (!mounted || token != _openToken) return;
      await _player.setVolume(_volume.toDouble());
      await _player.setRate(_speed);
      unawaited(_maybeSkipIntro(token));
      unawaited(_readDecoder(token));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 设置 mpv 的解码 / 缓存参数。
  ///
  /// 全部走 dynamic + try/catch：media_kit 的 setProperty 在 Dart 侧是
  /// 内部 API（版本一升就可能改名），这样写既不影响编译，真拿不到
  /// 也只是"退化成默认值"，不会白屏。
  Future<void> _applyDecodeOptions() async {
    final wantHw = app.store.hwDecode;

    // 网络播放的缓冲：默认值对高码率 1080p 太小，会反复 buffering
    await _setProp('cache', 'yes');
    await _setProp('cache-secs', '30');
    await _setProp('demuxer-readahead-secs', '30');
    await _setProp('demuxer-max-bytes', '128MiB');
    await _setProp('demuxer-max-back-bytes', '32MiB');

    if (!wantHw) {
      await _setProp('hwdec', 'no');
      _decoder = '软解（设置里可改回硬解）';
      return;
    }
    // mediacodec-copy 在安卓盒子上兼容性最好：先解到内存再上屏，
    // 不会出现某些 GPU 直接绿屏/黑屏的问题。失败再退 mediacodec。
    for (final m in const ['mediacodec-copy', 'mediacodec', 'auto-safe']) {
      if (await _setProp('hwdec', m)) {
        _decoder = '硬解 $m（打开后自动确认）';
        return;
      }
    }
    _decoder = '软解（这台机器的解码器不认硬解参数）';
  }

  Future<bool> _setProp(String key, String value) async {
    try {
      // 用 dynamic 拿 platform：media_kit 的 setProperty 是内部 API，
      // 直接写死类型的话，哪天升级把它挪走就编译不过了。
      await ((_player as dynamic).platform as dynamic).setProperty(key, value);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 播放起来之后读一次 hwdec-current，把真实在用的解码方式显示出来
  Future<void> _readDecoder(int token) async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted || token != _openToken) return;
      if (_player.state.position > Duration.zero) break;
    }
    try {
      final cur = await ((_player as dynamic).platform as dynamic)
          .getProperty('hwdec-current');
      if (!mounted || token != _openToken) return;
      final s = '$cur';
      setState(() => _decoder = (s.isEmpty || s == 'no') ? '软解' : '硬解 $s');
    } catch (_) {
      // 读不到就算了，面板上保持"未知"
    }
  }

  /// 跳过片头。
  ///
  /// v1.5 的写法有个致命问题：open() 刚返回就去看时长，这时 mpv 还没解出
  /// 文件头，duration 一直是 0，循环 3 秒后就放弃了 —— 所以用户会觉得
  /// "设置了没反应"。现在改成：等真正开始播（position > 0）之后再看时长，
  /// 跳过去还会回读位置确认，没跳成功再试，最多 3 次。
  Future<void> _maybeSkipIntro(int token) async {
    final skip = _skipStart;
    if (skip <= 0) return;

    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted || token != _openToken) return;
      if (_error != null) return;

      final d = _player.state.duration;
      final p = _player.state.position;

      // 时长还没出来：继续等（最多 10 秒）
      if (d <= Duration.zero) continue;

      // 片子比片头还短，跳过就没了 —— 不跳
      if (d.inSeconds <= skip + 5) return;

      // 已经在片头之后了，不用跳
      if (p.inSeconds + 1 >= skip) return;

      await _player.seek(Duration(seconds: skip));
      // 回读确认：跳成功就收工，没成功再试
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted || token != _openToken) return;
      if (_player.state.position.inSeconds + 2 >= skip) {
        _posN.value = _player.state.position;
        return;
      }
    }
  }

  /// 跳过片尾：离结束还剩 _skipEnd 秒时自动下一个
  void _checkSkipEnd(Duration p) {
    if (_skipEnd <= 0 || _endReached) return;
    if (_dur <= Duration.zero) return;
    // 片尾长度 >= 整片长度 = 一播就跳，会变成死循环（单个循环模式下）
    if (_skipEnd >= _dur.inSeconds - 2) return;
    final remain = _dur - p;
    if (remain <= Duration(seconds: _skipEnd) && remain > Duration.zero) {
      _endReached = true;
      _autoAdvance();
    }
  }

  void _onCompleted() {
    if (_layer != _Layer.none && mounted) setState(() => _ui = true);
    _autoAdvance();
  }

  /// 按播放模式决定下一个播什么
  void _autoAdvance() {
    if (widget.files.isEmpty) return;
    switch (_mode) {
      case PlayMode.order:
        if (_index + 1 < widget.files.length) {
          _playAt(_index + 1);
        } else if (mounted) {
          setState(() => _ui = true);
        }
        break;
      case PlayMode.repeatOne:
        _player.seek(Duration.zero);
        _player.play();
        _posN.value = Duration.zero;
        setState(() => _endReached = false);
        break;
      case PlayMode.shuffle:
        if (widget.files.length == 1) {
          _player.seek(Duration.zero);
          _player.play();
        } else {
          var n = _index;
          final r = math.Random();
          while (n == _index) {
            n = r.nextInt(widget.files.length);
          }
          _playAt(n);
        }
        break;
      case PlayMode.loopDir:
        _playAt((_index + 1) % widget.files.length);
        break;
    }
  }

  void _playAt(int i) {
    if (i < 0 || i >= widget.files.length) return;
    setState(() => _index = i);
    _open();
  }

  void _next() {
    if (_index + 1 >= widget.files.length) return;
    _playAt(_index + 1);
  }

  void _prev() {
    if (_index <= 0) return;
    _playAt(_index - 1);
  }

  Future<void> _seekBy(int seconds) async {
    var target = _pos + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (_dur > Duration.zero && target > _dur) target = _dur;
    await _player.seek(target);
    _posN.value = target;
  }

  Future<void> _seekToFraction(double f) async {
    if (_dur <= Duration.zero) return;
    var v = f;
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    final target = Duration(milliseconds: (v * _dur.inMilliseconds).round());
    await _player.seek(target);
    _posN.value = target;
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

  Future<void> _setSpeed(double v) async {
    await app.updateSetting(() => app.store.setSpeed(v));
    await _player.setRate(v);
    if (mounted) setState(() {});
  }

  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0];

  Future<void> _speedStep(int d) async {
    final i = _nearestSpeedIndex(_speed);
    final n = clampInt(i + d, 0, _speeds.length - 1);
    await _setSpeed(_speeds[n]);
  }

  /// 单击循环：3× 之后回到 0.5×
  Future<void> _speedCycle() async {
    final i = _nearestSpeedIndex(_speed);
    final n = (i + 1) % _speeds.length;
    await _setSpeed(_speeds[n]);
  }

  static int _nearestSpeedIndex(double v) {
    var best = 0;
    var diff = 999.0;
    for (var i = 0; i < _speeds.length; i++) {
      final d = (_speeds[i] - v).abs();
      if (d < diff) {
        diff = d;
        best = i;
      }
    }
    return best;
  }

  Future<void> _modeStep(int d) async {
    final m = d >= 0 ? _mode.next : _mode.prev;
    await app.updateSetting(() => app.store.setPlayMode(m));
    if (mounted) setState(() {});
  }

  /// 记住「片头」= 当前播放位置（只对当前目录生效）
  Future<void> _markSkipStart() async {
    if (_pos.inSeconds < 3) {
      _toast('现在才 0 秒，先往后拖一点再点「跳过片头」');
      return;
    }
    await app.updateSetting(
        () => app.store.setSkipOf(_dir, start: _pos.inSeconds));
    if (mounted) setState(() {});
    _toast('已记住：这个文件夹的视频从 ${fmtDuration(_pos)} 开始播');
  }

  Future<void> _markSkipEnd() async {
    if (_dur <= Duration.zero) {
      _toast('还没拿到视频时长，过几秒再试');
      return;
    }
    if (_pos.inSeconds < 10) {
      _toast('先往后拖一点，快到片尾再点（不然一播就跳）');
      return;
    }
    final remain = (_dur - _pos).inSeconds;
    if (remain <= 0) {
      _toast('已经到结尾了，先把进度往前拖一点');
      return;
    }
    await app.updateSetting(() => app.store.setSkipOf(_dir, end: remain));
    if (mounted) setState(() => _endReached = false);
    _toast('已记住：这个文件夹的视频最后 ${fmtDuration(Duration(seconds: remain))} 自动跳过');
  }

  Future<void> _resetSkipStart() async {
    await app.updateSetting(() => app.store.setSkipOf(_dir, start: 0));
    if (mounted) setState(() {});
    _toast('已重置这个文件夹的「跳过片头」');
  }

  Future<void> _resetSkipEnd() async {
    await app.updateSetting(() => app.store.setSkipOf(_dir, end: 0));
    if (mounted) setState(() {});
    _toast('已重置这个文件夹的「跳过片尾」');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(milliseconds: 1600),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ------------------------------------------------------------- UI 显隐

  void _scheduleHide() {
    _hideTimer?.cancel();
    // 面板开着的时候不要自动隐藏控制条（否则调音量会把界面调没）
    if (_layer != _Layer.none) return;
    if (!_ui) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _ui = false);
    });
  }

  void _showUi() {
    if (!_ui) setState(() => _ui = true);
    _scheduleHide();
  }

  void _openLayer(_Layer l) {
    setState(() {
      _layer = l;
      _ui = true;
      _menuIndex = 0;
      if (l == _Layer.playlist) _plIndex = _index;
    });
    _hideTimer?.cancel();
    if (l == _Layer.playlist) _scrollPlaylistTo(_index);
  }

  void _closeLayer() {
    setState(() => _layer = _Layer.none);
    _scheduleHide();
  }

  void _scrollPlaylistTo(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_plScroll.hasClients) return;
      const rowH = 58.0;
      final top = i * rowH;
      final vp = _plScroll.position.viewportDimension;
      if (top < _plScroll.offset) {
        _plScroll.jumpTo(top);
      } else if (top + rowH > _plScroll.offset + vp) {
        _plScroll.jumpTo(top + rowH - vp);
      }
    });
  }

  // ------------------------------------------------------------- 按键

  static const int _menuRows = 7; // 0列表 1模式 2倍速 3音量 4片头 5片尾 6关闭

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (_layer == _Layer.none) return _onPlayerKey(e);
    if (_layer == _Layer.playlist) return _onPlaylistKey(e);
    return _onMenuKey(e);
  }

  KeyEventResult _onPlayerKey(KeyEvent e) {
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
    // v1.6：上下键改成切上一个/下一个视频（音量挪进播放面板）
    if (isUp(e)) {
      if (_index > 0) {
        _prev();
      } else {
        _toast('已经是第一个了');
      }
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      if (_index + 1 < widget.files.length) {
        _next();
      } else {
        _toast('已经是最后一个了');
      }
      return KeyEventResult.handled;
    }
    if (isSelect(e) || isPlayPause(e)) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (isMenu(e)) {
      _openLayer(_Layer.menu);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onMenuKey(KeyEvent e) {
    // 长按 OK：
    //   倍速行 = 回 1×
    //   片头/片尾行 = 重置
    // 其余行短按即可
    if (isSelect(e)) {
      final isHoldRow = _menuIndex == 2 || _menuIndex == 4 || _menuIndex == 5;
      if (e is KeyDownEvent && isHoldRow) {
        _holdFired = false;
        _holdTimer?.cancel();
        _holdTimer = Timer(const Duration(milliseconds: 600), () {
          _holdFired = true;
          _activateRow(long: true);
        });
        return KeyEventResult.handled;
      }
      if (e is KeyUpEvent && isHoldRow) {
        _holdTimer?.cancel();
        if (!_holdFired) _activateRow(long: false);
        _holdFired = false;
        return KeyEventResult.handled;
      }
      if (e is KeyUpEvent) return KeyEventResult.ignored;
      if (e is KeyDownEvent) {
        _activateRow(long: false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (e is KeyUpEvent) return KeyEventResult.ignored;

    if (isUp(e)) {
      setState(() => _menuIndex = (_menuIndex - 1 + _menuRows) % _menuRows);
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      setState(() => _menuIndex = (_menuIndex + 1) % _menuRows);
      return KeyEventResult.handled;
    }
    if (isLeft(e)) {
      if (_menuIndex == 1) _modeStep(-1);
      if (_menuIndex == 2) _speedStep(-1);
      if (_menuIndex == 3) _volumeBy(-5);
      return KeyEventResult.handled;
    }
    if (isRight(e)) {
      if (_menuIndex == 1) _modeStep(1);
      if (_menuIndex == 2) _speedStep(1);
      if (_menuIndex == 3) _volumeBy(5);
      return KeyEventResult.handled;
    }
    if (isMenu(e)) {
      _closeLayer();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onPlaylistKey(KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final n = widget.files.length;

    if (isUp(e)) {
      if (n > 0) {
        setState(() => _plIndex = clampInt(_plIndex - 1, 0, n - 1));
        _scrollPlaylistTo(_plIndex);
      }
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      if (n > 0) {
        setState(() => _plIndex = clampInt(_plIndex + 1, 0, n - 1));
        _scrollPlaylistTo(_plIndex);
      }
      return KeyEventResult.handled;
    }
    if (isSelect(e)) {
      _closeLayer();
      _playAt(_plIndex);
      return KeyEventResult.handled;
    }
    if (isLeft(e) || isMenu(e)) {
      _closeLayer();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _activateRow({required bool long}) {
    switch (_menuIndex) {
      case 0:
        _openLayer(_Layer.playlist);
        break;
      case 1:
        _modeStep(1);
        break;
      case 2:
        if (long) {
          _setSpeed(1);
          _toast('已回到 1×');
        } else {
          _speedCycle();
        }
        break;
      case 3:
        _volumeBy(5);
        break;
      case 4:
        if (long) {
          _resetSkipStart();
        } else {
          _markSkipStart();
        }
        break;
      case 5:
        if (long) {
          _resetSkipEnd();
        } else {
          _markSkipEnd();
        }
        break;
      case 6:
        _closeLayer();
        break;
    }
  }

  // ------------------------------------------------------------- 渲染

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 有面板时返回键先关面板，别一下退出播放
      canPop: _layer == _Layer.none,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _closeLayer();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_layer != _Layer.none) {
                _closeLayer();
              } else if (_ui) {
                setState(() => _ui = false);
                _hideTimer?.cancel();
              } else {
                _showUi();
              }
            },
            child: Stack(
              children: [
                Positioned.fill(child: _surface()),
                if (_buffering && _error == null)
                  const Center(
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
                if (_ui) _topBar(),
                if (_ui) _bottomBar(),
                if (_layer == _Layer.playlist) _playlistLayer(),
                if (_layer == _Layer.menu) _menuLayer(),
              ],
            ),
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
                  '常见原因：格式不被支持 / 服务器不支持 Range / 网络断了\n'
                  '可以试试「设置 → 视频硬解」关掉再放一次',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: TvColors.textDim),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _topBar() => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Builder(builder: (context) {
          final compact = isCompact(context);
          return Container(
            height: compact ? 78 : 104,
            padding: EdgeInsets.fromLTRB(
                compact ? 14 : 26, compact ? 12 : 20, 10, 8),
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
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _cur.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: compact ? 16 : 19,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_index + 1} / ${widget.files.length}'
                        '${_isVideo ? '' : ' · 音频'}'
                        ' · ${_mode.label} · ${_fmtSpeed(_speed)}'
                        '${_skipStart > 0 ? ' · 跳片头 ${fmtDuration(Duration(seconds: _skipStart))}' : ''}'
                        '${_skipEnd > 0 ? ' · 跳片尾 ${_skipEnd}s' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
          );
        }),
      );

  Widget _bottomBar() {
    final compact = isCompact(context);

    final transport = <Widget>[
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
    ];

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
            compact ? 12 : 28, compact ? 10 : 26, compact ? 12 : 28, compact ? 10 : 22),
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
            // 只有这一块跟着进度值重画，视频画面不参与
            ValueListenableBuilder<Duration>(
              valueListenable: _posN,
              builder: (context, pos, _) => _ProgressBar(
                pos: pos,
                dur: _dur,
                onSeek: _seekToFraction,
              ),
            ),
            const SizedBox(height: 6),
            if (compact) ...[
              Row(
                children: [
                  ValueListenableBuilder<Duration>(
                    valueListenable: _posN,
                    builder: (context, pos, _) => Text(
                      '${fmtDuration(pos)} / ${fmtDuration(_dur)}',
                      style: const TextStyle(
                          fontSize: 12.5, color: TvColors.textDim),
                    ),
                  ),
                  const Spacer(),
                  _CtlBtn(
                    icon: Icons.format_list_bulleted_rounded,
                    onTap: () => _openLayer(_Layer.playlist),
                  ),
                  _CtlBtn(
                    icon: Icons.tune_rounded,
                    onTap: () => _openLayer(_Layer.menu),
                  ),
                  const SizedBox(width: 6),
                  Text(_fmtSpeed(_speed),
                      style: const TextStyle(
                          fontSize: 13, color: TvColors.textDim)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: transport,
              ),
            ] else
              Row(
                children: [
                  ValueListenableBuilder<Duration>(
                    valueListenable: _posN,
                    builder: (context, pos, _) => Text(
                      '${fmtDuration(pos)} / ${fmtDuration(_dur)}',
                      style: const TextStyle(
                          fontSize: 13, color: TvColors.textDim),
                    ),
                  ),
                  const SizedBox(width: 18),
                  _CtlBtn(
                    icon: Icons.format_list_bulleted_rounded,
                    tooltip: '目录列表',
                    onTap: () => _openLayer(_Layer.playlist),
                  ),
                  _CtlBtn(
                    icon: Icons.tune_rounded,
                    tooltip: '播放设置',
                    onTap: () => _openLayer(_Layer.menu),
                  ),
                  const Spacer(),
                  ...transport,
                  const SizedBox(width: 14),
                  Text(_fmtSpeed(_speed),
                      style: const TextStyle(
                          fontSize: 13, color: TvColors.textDim)),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 面板

  Widget _menuLayer() {
    final rows = <Widget>[
      _MenuRow(
        icon: Icons.format_list_bulleted_rounded,
        title: '目录列表',
        value: '${widget.files.length} 个文件',
        focused: _menuIndex == 0,
        onTap: () => _activateRow(long: false),
      ),
      _MenuRow(
        icon: _mode.icon,
        title: '播放模式',
        value: _mode.label,
        hint: '← → 切换',
        focused: _menuIndex == 1,
        onTap: () => _modeStep(1),
      ),
      _MenuRow(
        icon: Icons.speed_rounded,
        title: '播放速度',
        value: _fmtSpeed(_speed),
        hint: '← → 微调 · OK 循环 · 长按回 1×',
        focused: _menuIndex == 2,
        onTap: _speedCycle,
      ),
      _MenuRow(
        icon: Icons.volume_up_rounded,
        title: '音量',
        value: '$_volume%',
        hint: '← → 调整（上下键已改为切换视频）',
        focused: _menuIndex == 3,
        onTap: () => _volumeBy(5),
      ),
      _MenuRow(
        icon: Icons.first_page_rounded,
        title: '跳过片头',
        value: _skipStart > 0 ? fmtDuration(Duration(seconds: _skipStart)) : '关闭',
        hint: '只对本文件夹生效 · OK 记住当前 · 长按重置',
        focused: _menuIndex == 4,
        onTap: _markSkipStart,
        onLongPress: _resetSkipStart,
      ),
      _MenuRow(
        icon: Icons.last_page_rounded,
        title: '跳过片尾',
        value: _skipEnd > 0 ? '最后 ${_skipEnd}s' : '关闭',
        hint: '只对本文件夹生效 · OK 记住剩余 · 长按重置',
        focused: _menuIndex == 5,
        onTap: _markSkipEnd,
        onLongPress: _resetSkipEnd,
      ),
      _MenuRow(
        icon: Icons.close_rounded,
        title: '关闭面板',
        value: '',
        hint: '解码：$_decoder',
        focused: _menuIndex == 6,
        onTap: _closeLayer,
      ),
    ];

    final compact = isCompact(context);
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: compact ? MediaQuery.sizeOf(context).width : 480,
        padding: EdgeInsets.fromLTRB(
            compact ? 12 : 22, compact ? 60 : 90, compact ? 12 : 22, 16),
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
            const Text('播放设置',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('↑↓ 选择 · OK 执行 · ← → 调值 · 菜单/返回 关闭',
                style: TextStyle(fontSize: 12.5, color: TvColors.textDim)),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(children: rows),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playlistLayer() {
    final compact = isCompact(context);
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: compact ? MediaQuery.sizeOf(context).width : 430,
        padding: EdgeInsets.fromLTRB(
            compact ? 12 : 18, compact ? 56 : 90, compact ? 12 : 18, 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [alpha(Colors.black, 0.94), alpha(Colors.black, 0.55)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('目录列表',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('↑↓ 选择 · OK 播放 · 返回 关闭',
                style: TextStyle(fontSize: 12.5, color: TvColors.textDim)),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                controller: _plScroll,
                itemCount: widget.files.length,
                itemBuilder: (context, i) {
                  final f = widget.files[i];
                  final focused = i == _plIndex;
                  final playing = i == _index;
                  return InkWell(
                    onTap: () {
                      _closeLayer();
                      _playAt(i);
                    },
                    child: Container(
                      height: 52,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: focused ? TvColors.cardActive : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: focused ? TvColors.focus : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 30,
                            child: playing
                                ? const Icon(Icons.graphic_eq_rounded,
                                    size: 18, color: TvColors.accent)
                                : Text('${i + 1}',
                                    style: const TextStyle(
                                        fontSize: 12, color: TvColors.textDim)),
                          ),
                          Expanded(
                            child: Text(
                              f.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight:
                                    playing ? FontWeight.w700 : FontWeight.w400,
                                color: playing ? TvColors.accent : TvColors.text,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtSpeed(double v) {
    final s = v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    return '$s×';
  }
}

/// 播放设置面板里的一行
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.focused,
    required this.onTap,
    this.hint,
    this.onLongPress,
  });

  final IconData icon;
  final String title;
  final String value;
  final String? hint;
  final bool focused;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                  size: 22,
                  color: focused ? TvColors.focus : TvColors.textDim),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 16.5, fontWeight: FontWeight.w600)),
                    if (hint != null) ...[
                      const SizedBox(height: 2),
                      Text(hint!,
                          style: const TextStyle(
                              fontSize: 11.5, color: TvColors.textDim)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(value,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: TvColors.accent)),
            ],
          ),
        ),
      ),
    );
  }
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
  const _CtlBtn({
    required this.icon,
    this.onTap,
    this.big = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool big;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final compact = isCompact(context);
    final size = big ? (compact ? 54.0 : 62.0) : (compact ? 42.0 : 46.0);
    final enabled = onTap != null;
    final btn = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
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
            size: big ? 34 : 24,
            color: enabled
                ? (big ? const Color(0xFF06222B) : Colors.white)
                : Colors.white24,
          ),
        ),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip!, child: btn);
  }
}
