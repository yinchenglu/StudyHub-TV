import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/fmt.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../data/downloader.dart';
import '../native/system_channel.dart';
import 'keys.dart';
import 'tv_widgets.dart';

/// 「工具 → 文件管理」：管电视本地的东西。
///
/// 为什么需要它：下载下来的电影看完了要删（电视存储就那么大），
/// 下载的 APK 要能点开安装，缩略图缓存吃了几百兆也得看得见。
/// 而 Android/data/<包名>/ 这个目录，电视自带的文件管理器大多进不去，
/// 所以必须在这儿自己给一个入口。
///
/// 遥控器操作：
///   ↑↓     移动
///   OK     进入文件夹 / 用系统应用打开文件（APK 会弹安装器）
///   菜单键  删除选中的文件或文件夹（先弹确认）
///   ←      返回上一级；已经在最外层就退出
class FileManagerPage extends StatefulWidget {
  const FileManagerPage({super.key});

  @override
  State<FileManagerPage> createState() => _FileManagerPageState();
}

/// 列表里的一行（文件夹 / 文件 / 操作项 都用它）
class _Row {
  _Row({
    required this.title,
    required this.sub,
    required this.icon,
    required this.onTap,
    this.onMenu,
    this.danger = false,
    this.trailing,
  });

  final String title;
  final String sub;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final bool danger;
  final String? trailing;
}

class _FileManagerPageState extends State<FileManagerPage> {
  final FocusNode _node = FocusNode(debugLabel: 'files');
  final ScrollController _scroll = ScrollController();

  /// 目录栈为空 = 停在"位置列表"
  final List<Directory> _stack = [];
  final List<String> _names = [];
  String _spotName = '';

  List<_Row> _rows = const [];
  bool _loading = true;
  int _index = 0;
  String _status = '';

  int _totalBytes = 0;
  int _totalFiles = 0;

  Directory? get _dir => _stack.isEmpty ? null : _stack.last;

  @override
  void initState() {
    super.initState();
    _node.addListener(_redraw);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _node.requestFocus();
      _loadSpots();
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

  Future<Directory> _thumbsDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}thumbs');
  }

  Future<Directory> _cacheDir() async {
    try {
      return await getTemporaryDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  /// 三个位置：下载的文件 / 缩略图缓存 / 临时缓存
  Future<void> _loadSpots() async {
    setState(() {
      _loading = true;
      _status = '';
    });
    final download = await Downloader.targetDir();
    final thumbs = await _thumbsDir();
    final cache = await _cacheDir();

    final specs = <(String, String, IconData, Directory, String)>[
      ('下载文件', '「软件下载」下到电视上的文件', Icons.download_done_rounded,
          download, 'download'),
      ('缩略图缓存', '视频封面，删了下次进目录会重新抽', Icons.image_outlined, thumbs,
          'thumbs'),
      ('临时缓存', '播放和网络产生的临时文件，可随时清', Icons.cleaning_services_outlined,
          cache, 'cache'),
    ];

    final rows = <_Row>[];
    var total = 0;
    for (final s in specs) {
      final (title, sub, icon, dir, tag) = s;
      final size = await _sizeOf(dir);
      total += size.$1;
      rows.add(_Row(
        title: title,
        sub: '$sub${size.$2 > 0 ? ' · ${size.$2} 个文件 · ${fmtBytes(size.$1)}' : ' · 空'}',
        icon: icon,
        trailing: size.$1 > 0 ? fmtBytes(size.$1) : '空',
        onTap: () => _enter(dir, title, tag),
      ));
    }

    if (!mounted) return;
    setState(() {
      _rows = rows;
      _totalBytes = total;
      _totalFiles = 0;
      _loading = false;
    });
  }

  Future<void> _enter(Directory dir, String name, String tag) async {
    _stack.add(dir);
    _names.add(name);
    _spotName = tag;
    await _loadDir();
  }

  Future<void> _loadDir() async {
    final dir = _dir;
    if (dir == null) {
      await _loadSpots();
      return;
    }
    setState(() {
      _loading = true;
      _status = '';
    });

    final rows = <_Row>[];
    var files = 0;
    var bytes = 0;

    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final entries = await dir.list(followLinks: false).toList();
      final dirs = <FileSystemEntity>[];
      final fs = <FileSystemEntity>[];
      for (final e in entries) {
        if (e is Directory) {
          dirs.add(e);
        } else if (e is File) {
          fs.add(e);
        }
      }
      String nameOf(FileSystemEntity e) =>
          e.path.split(Platform.pathSeparator).last;
      dirs.sort((a, b) => naturalCompare(nameOf(a), nameOf(b)));
      fs.sort((a, b) => naturalCompare(nameOf(a), nameOf(b)));

      for (final e in dirs) {
        final d = e as Directory;
        final sub = await _sizeOf(d);
        rows.add(_Row(
          title: nameOf(e),
          sub: sub.$2 > 0 ? '文件夹 · ${sub.$2} 个文件 · ${fmtBytes(sub.$1)}' : '空文件夹',
          icon: Icons.folder_rounded,
          trailing: '${sub.$2}',
          onTap: () => _enter(d, nameOf(e), _spotName),
          onMenu: () => _delete(e, nameOf(e), isDir: true),
        ));
      }

      for (final e in fs) {
        final f = e as File;
        var len = 0;
        var when = '';
        try {
          len = await f.length();
          final st = await f.stat();
          when = fmtTime(st.modified);
        } catch (_) {}
        files++;
        bytes += len;
        final n = nameOf(e);
        rows.add(_Row(
          title: n,
          sub: '${fmtBytes(len)}${when.isEmpty ? '' : ' · $when'}',
          icon: _iconFor(n),
          trailing: '打开',
          onTap: () => _openFile(f),
          onMenu: () => _delete(f, n, isDir: false),
        ));
      }
    } catch (e) {
      _status = '读不了这个目录：$e';
    }

    if (!mounted) return;
    setState(() {
      _rows = rows;
      _totalBytes = bytes;
      _totalFiles = files;
      _loading = false;
      _index = 0;
    });
  }

  /// 递归统计（文件和字节数）。限制深度，避免软链接打转。
  Future<(int, int)> _sizeOf(Directory dir, [int depth = 0]) async {
    if (depth > 6) return (0, 0);
    var bytes = 0;
    var count = 0;
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is File) {
          try {
            bytes += await e.length();
            count++;
          } catch (_) {}
        } else if (e is Directory) {
          final sub = await _sizeOf(e, depth + 1);
          bytes += sub.$1;
          count += sub.$2;
        }
      }
    } catch (_) {}
    return (bytes, count);
  }

  IconData _iconFor(String name) {
    final ext = extOf(name);
    if (ext == 'apk') return Icons.android_rounded;
    if (kImageExts.contains(ext)) return Icons.image_outlined;
    if (kVideoExts.contains(ext)) return Icons.movie_outlined;
    if (kAudioExts.contains(ext)) return Icons.audiotrack_rounded;
    return Icons.insert_drive_file_outlined;
  }

  // ------------------------------------------------------------- 动作

  Future<void> _openFile(File f) async {
    final ok = await SystemChannel.openFile(f.path);
    if (!mounted) return;
    setState(() {
      _status = ok
          ? '已交给系统打开：${f.path.split(Platform.pathSeparator).last}'
          : '打不开这个文件（电视上可能没有能处理它的应用）。位置：${f.path}';
    });
    _node.requestFocus();
  }

  Future<void> _delete(FileSystemEntity e, String name,
      {required bool isDir}) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: Text(isDir ? '删除文件夹？' : '删除文件？'),
        content: Text(
          isDir
              ? '「$name」里的所有东西都会被删掉，不能恢复。'
              : '「$name」会被删掉，不能恢复。',
          style: const TextStyle(fontSize: 15, height: 1.5),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: TvColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true) {
      _node.requestFocus();
      return;
    }
    try {
      await e.delete(recursive: true);
      if (!mounted) return;
      setState(() => _status = '已删除：$name');
    } catch (err) {
      if (!mounted) return;
      setState(() => _status = '删不掉：$err');
    }
    _node.requestFocus();
    await _loadDir();
  }

  Future<void> _clearDir() async {
    final dir = _dir;
    if (dir == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: const Text('清空这个文件夹？'),
        content: Text(
          '「$_spotName」里的 ${_totalFiles} 个文件（${fmtBytes(_totalBytes)}）'
          '会被全部删掉，子文件夹也一起删，不能恢复。',
          style: const TextStyle(fontSize: 15, height: 1.5),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('全部删除', style: TextStyle(color: TvColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true) {
      _node.requestFocus();
      return;
    }
    var freed = 0;
    try {
      await for (final e in dir.list(followLinks: false)) {
        try {
          if (e is File) freed += await e.length();
          await e.delete(recursive: true);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _status = '已清空，释放 ${fmtBytes(freed)}');
    } catch (err) {
      if (!mounted) return;
      setState(() => _status = '清空失败：$err');
    }
    _node.requestFocus();
    await _loadDir();
  }

  Future<void> _up() async {
    if (_stack.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    _stack.removeLast();
    _names.removeLast();
    if (_stack.isEmpty) {
      await _loadSpots();
    } else {
      await _loadDir();
    }
  }

  // ------------------------------------------------------------- 按键

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final n = _rows.length;

    if (isUp(e)) {
      _move(_index - 1);
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      _move(_index + 1);
      return KeyEventResult.handled;
    }
    if (isLeft(e)) {
      _up();
      return KeyEventResult.handled;
    }
    if (isMenu(e)) {
      if (n > 0) {
        final r = _rows[clampInt(_index, 0, n - 1)];
        if (r.onMenu != null) {
          r.onMenu!();
        } else {
          setState(() => _status = '这一项没有可删除的内容');
        }
      }
      return KeyEventResult.handled;
    }
    if (isSelect(e) || isRight(e)) {
      if (n == 0) {
        _loadDir();
      } else {
        _rows[clampInt(_index, 0, n - 1)].onTap();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int v) {
    if (_rows.isEmpty) return;
    final next = clampInt(v, 0, _rows.length - 1);
    if (next == _index) return;
    setState(() => _index = next);
    if (!_scroll.hasClients) return;
    const rowH = 70.0;
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
                    : (_stack.isEmpty
                        ? '选一个位置，按 OK 进入'
                        : 'OK 打开 · 菜单键 删除选中的项 · ← 返回上一级'),
                warn: _status.contains('失败') ||
                    _status.contains('删不掉') ||
                    _status.contains('打不开'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final compact = isCompact(context);
    final title = _stack.isEmpty ? '文件管理' : _names.join(' / ');
    return PageHeader(
      title: _stack.isEmpty ? '文件管理' : '文件管理 · $title',
      subtitle: _stack.isEmpty
          ? '电视本地的文件，都在这里'
          : '${_totalFiles} 个文件 · ${fmtBytes(_totalBytes)}',
      leading: IconButton(
        onPressed: () => _stack.isEmpty ? Navigator.of(context).pop() : _up(),
        icon: const Icon(Icons.arrow_back),
        tooltip: '返回',
      ),
      actions: [
        if (_stack.isEmpty && _totalBytes > 0 && !compact)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '合计 ${fmtBytes(_totalBytes)}',
              style: const TextStyle(fontSize: 13, color: TvColors.textDim),
            ),
          ),
        if (_stack.isEmpty)
          compact
              ? IconButton(
                  onPressed: _loadSpots,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: '刷新',
                )
              : TextButton.icon(
                  onPressed: _loadSpots,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('刷新'),
                )
        else
          compact
              ? IconButton(
                  onPressed: _clearDir,
                  icon: const Icon(Icons.delete_sweep_outlined,
                      color: TvColors.danger),
                  tooltip: '清空',
                )
              : TextButton.icon(
                  onPressed: _clearDir,
                  icon: const Icon(Icons.delete_sweep_outlined,
                      size: 18, color: TvColors.danger),
                  label: const Text('清空',
                      style: TextStyle(color: TvColors.danger)),
                ),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_rows.isEmpty) {
      return EmptyHint(
        _stack.isEmpty ? '没有可访问的本地目录' : '这个文件夹是空的',
        icon: Icons.folder_open_rounded,
      );
    }
    return LayoutBuilder(
      builder: (context, c) => Center(
        child: SizedBox(
          width: c.maxWidth > 900 ? 900 : c.maxWidth,
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(pagePad(context), 6, pagePad(context), 22),
            itemCount: _rows.length,
            itemBuilder: (context, i) => _row(_rows[i], i),
          ),
        ),
      ),
    );
  }

  Widget _row(_Row r, int i) {
    final focused = _node.hasFocus && i == _index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: SizedBox(
        height: 66,
        child: TvRow(
          focused: focused,
          title: r.title,
          subtitle: r.sub,
          danger: r.danger,
          leading: Icon(r.icon,
              size: 22, color: r.danger ? TvColors.danger : TvColors.textDim),
          trailing: r.trailing == null
              ? null
              : Text(
                  r.trailing!,
                  style: const TextStyle(fontSize: 14, color: TvColors.textDim),
                ),
          onTap: () {
            setState(() => _index = i);
            _node.requestFocus();
            r.onTap();
          },
        ),
      ),
    );
  }
}
