import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fmt.dart';
import '../core/theme.dart';
import '../data/downloader.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'keys.dart';
import 'tv_widgets.dart';

/// 「工具 → 下载工作」
///
/// 看的是服务器上 `StudyHub-TV/download` 里的东西：可以进子目录，
/// 选中文件按 OK 就把它下到电视本地（应用专属目录，不要权限）。
///
/// 为什么不做后台下载队列：
///   电视的内存和存储都很紧，同时下三个只会三个都下不完。
///   这里一次只下一个，进度实时显示，断了自己重按一下就是续传
///   （服务器支持 Range 时会从断点续，不支持的会从头开始）。
class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key, required this.app});

  final AppState app;

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  final FocusNode _node = FocusNode(debugLabel: 'downloads');
  final ScrollController _scroll = ScrollController();

  String _rel = '';
  List<RemoteEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  int _index = 0;

  /// 本地已有的文件：文件名 → 字节数
  Map<String, int> _local = {};

  /// 正在下载的文件路径 → 进度 0..1
  final Map<String, double> _progress = {};
  String? _busyPath;
  String _status = '';

  AppState get app => widget.app;

  String get _base => app.downloadBase;

  String get _abs => _rel.isEmpty ? _base : '$_base/$_rel';

  @override
  void initState() {
    super.initState();
    _node.addListener(_redraw);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _node.requestFocus();
      _load();
    });
  }

  @override
  void dispose() {
    _node.removeListener(_redraw);
    _scroll.dispose();
    _node.dispose();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------- 数据

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final local = <String, int>{};
    try {
      final dir = await Downloader.targetDir();
      await for (final f in dir.list()) {
        if (f is File) {
          final name = f.path.split(Platform.pathSeparator).last;
          local[name] = await f.length();
        }
      }
    } catch (_) {}
    try {
      final list = await app.listPath(_abs);
      if (!mounted) return;
      setState(() {
        _local = local;
        _entries = list;
        _loading = false;
        _index = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _local = local;
        _entries = const [];
        _error = '$e\n\n这个目录没找到：$_abs\n'
            '在服务器上建一个 download 文件夹（放在 StudyHub-TV 下面）就能看到内容。';
        _loading = false;
      });
    }
  }

  Future<void> _enter(String rel) async {
    _rel = rel;
    await _load();
  }

  Future<void> _up() async {
    if (_rel.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final i = _rel.lastIndexOf('/');
    _rel = i < 0 ? '' : _rel.substring(0, i);
    await _load();
  }

  // ------------------------------------------------------------- 下载

  Future<void> _download(RemoteEntry e) async {
    if (_busyPath != null) {
      setState(() => _status = '正在下载「${_fileOf(_busyPath!).name}」，等它下完再点别的');
      return;
    }
    final name = Downloader.safeName(e.name);
    final existing = _local[name];
    if (existing != null && (e.size <= 0 || existing == e.size)) {
      setState(() => _status = '「$name」已经下载过了（${fmtBytes(existing)}）');
      return;
    }

    setState(() {
      _busyPath = e.path;
      _progress[e.path] = 0;
      _status = '开始下载：${e.name}';
    });

    try {
      final ref = app.ref(e.path);
      final file = await Downloader.fetch(
        ref,
        e.name,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _progress[e.path] = total > 0 ? received / total : 0;
            _status = total > 0
                ? '下载中：${fmtBytes(received)} / ${fmtBytes(total)}（${(received * 100 / total).toStringAsFixed(0)}%）'
                : '下载中：${fmtBytes(received)}';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _progress.remove(e.path);
        _busyPath = null;
        _status = '已保存：${file.path}';
      });
      await _load();
      if (mounted) setState(() => _status = '已保存：${file.path}');
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _progress.remove(e.path);
        _busyPath = null;
        _status = '下载失败：$err';
      });
    }
  }

  RemoteEntry _fileOf(String path) =>
      _entries.firstWhere((e) => e.path == path,
          orElse: () => const RemoteEntry(path: '?', isDir: false));

  // ------------------------------------------------------------- 按键

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final n = _entries.length;

    if (isUp(e)) {
      _move(_index - 1);
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      _move(_index + 1);
      return KeyEventResult.handled;
    }
    if (isLeft(e) || isMenu(e)) {
      if (isMenu(e)) {
        _load();
      } else {
        _up();
      }
      return KeyEventResult.handled;
    }
    if (isSelect(e) || isRight(e)) {
      if (n == 0) {
        _load();
      } else {
        final it = _entries[clampInt(_index, 0, n - 1)];
        if (it.isDir) {
          _enter(it.path);
        } else {
          _download(it);
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int v) {
    if (_entries.isEmpty) return;
    final next = clampInt(v, 0, _entries.length - 1);
    if (next == _index) return;
    setState(() => _index = next);
    if (!_scroll.hasClients) return;
    const rowH = 76.0;
    final top = next * rowH;
    final vp = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.animateTo(top,
          duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
    } else if (top + rowH > _scroll.offset + vp) {
      _scroll.animateTo(top + rowH - vp,
          duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
    }
  }

  // ------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvColors.bg,
      body: SafeArea(
        child: Focus(
          focusNode: _node,
          onKeyEvent: _onKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              Expanded(child: _body()),
              StatusBar(
                text: _status.isNotEmpty
                    ? _status
                    : '目录：$_abs   ·   OK 下载 / 进入   ·   ← 返回上级',
                warn: _status.startsWith('下载失败'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final segs = _rel.split('/').where((e) => e.isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回工具',
          ),
          const SizedBox(width: 6),
          const Text('下载工作',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              children: [
                GestureDetector(
                  onTap: () => _enter(''),
                  child: Text('download',
                      style: TextStyle(
                        fontSize: 15,
                        color: segs.isEmpty ? TvColors.text : TvColors.textDim,
                        fontWeight:
                            segs.isEmpty ? FontWeight.w700 : FontWeight.w400,
                      )),
                ),
                for (var i = 0; i < segs.length; i++) ...[
                  const Icon(Icons.chevron_right,
                      size: 16, color: TvColors.textDim),
                  GestureDetector(
                    onTap: () => _enter(segs.take(i + 1).join('/')),
                    child: Text(
                      segs[i],
                      style: TextStyle(
                        fontSize: 15,
                        color: i == segs.length - 1
                            ? TvColors.text
                            : TvColors.textDim,
                        fontWeight: i == segs.length - 1
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!_loading)
            Text('${_entries.length} 项',
                style: const TextStyle(fontSize: 13, color: TvColors.textDim)),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ErrorBox(message: _error!, onRetry: _load),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const EmptyHint('download 文件夹是空的', icon: Icons.download_outlined);
    }

    return LayoutBuilder(
      builder: (context, c) => Center(
        child: SizedBox(
          width: c.maxWidth > 900 ? 900 : c.maxWidth,
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(22, 6, 22, 22),
            itemCount: _entries.length,
            itemBuilder: (context, i) => _row(_entries[i], i),
          ),
        ),
      ),
    );
  }

  Widget _row(RemoteEntry e, int i) {
    final focused = _node.hasFocus && i == _index;
    final p = _progress[e.path];
    final name = Downloader.safeName(e.name);
    final localSize = _local[name];
    final done = localSize != null && (e.size <= 0 || localSize == e.size);

    String sub;
    if (e.isDir) {
      sub = '文件夹 — OK 进入';
    } else if (p != null) {
      sub = '下载中 ${(p * 100).toStringAsFixed(0)}%';
    } else if (done) {
      sub = '已在本地 · ${fmtBytes(localSize)}';
    } else {
      sub = e.size > 0 ? fmtBytes(e.size) : '大小未知';
      if (localSize != null) sub += ' · 本地有个 ${fmtBytes(localSize)} 的同名文件';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: SizedBox(
        height: 68,
        child: TvRow(
          focused: focused,
          title: e.name,
          subtitle: sub,
          leading: Icon(
            e.isDir
                ? Icons.folder_outlined
                : (done ? Icons.check_circle_outline : Icons.insert_drive_file_outlined),
            size: 22,
            color: done && !e.isDir ? TvColors.accent : TvColors.textDim,
          ),
          trailing: p != null
              ? SizedBox(
                  width: 90,
                  child: LinearProgressIndicator(
                    value: p <= 0 ? null : p,
                    minHeight: 6,
                    backgroundColor: TvColors.divider,
                  ),
                )
              : (e.isDir
                  ? const Icon(Icons.chevron_right, color: TvColors.textDim)
                  : Text(done ? '已下载' : '下载',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: done ? TvColors.textDim : TvColors.accent,
                      ))),
          onTap: () {
            setState(() => _index = i);
            _node.requestFocus();
            if (e.isDir) {
              _enter(e.path);
            } else {
              _download(e);
            }
          },
        ),
      ),
    );
  }
}
