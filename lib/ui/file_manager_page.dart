import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fmt.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../native/system_channel.dart';
import '../state/app_state.dart';
import 'keys.dart';
import 'tv_widgets.dart';

/// 「工具 → 文件管理」（v1.5 重写：从"只能看和装"升级成真文件管理器）。
///
/// 能干什么：
///   浏览整台电视的存储（不是只有 App 自己的目录）、进/退目录、
///   打开文件、复制 / 剪切 / 粘贴、重命名、删除、压缩成 zip、解压 zip、
///   新建文件夹、上传到服务器的 download 目录。
///
/// 为什么先问一次"所有文件访问"：
///   安卓 11（API 30）起，普通应用只能读写自己的目录和公共媒体目录。
///   要浏览 /sdcard 下任意位置（例如 U 盘、别的应用留下的文件夹），
///   必须在系统设置里手动授予 MANAGE_EXTERNAL_STORAGE。
///   这个权限没法用代码弹框申请，只能跳到系统页面让用户自己开，
///   所以页面上给了个显眼的按钮，没开的时候如实提示"只能看自己目录"。
class FileManagerPage extends StatefulWidget {
  const FileManagerPage({super.key, required this.app});

  final AppState app;

  @override
  State<FileManagerPage> createState() => _FileManagerPageState();
}

class _FileManagerPageState extends State<FileManagerPage> {
  final FocusNode _node = FocusNode(debugLabel: 'files');
  final ScrollController _scroll = ScrollController();

  String _cwd = '';
  String _root = '';
  List<FileSystemEntity> _items = const [];
  bool _loading = true;
  int _index = 0;
  String _status = '';

  StorageInfo? _storage;

  /// 剪贴板：要复制/移动的路径，以及是"剪切"还是"复制"
  List<String> _clip = const [];
  bool _clipCut = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_redraw);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _node.requestFocus();
      _boot();
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

  // ------------------------------------------------------------- 路径

  String _join(String a, String b) {
    if (a.isEmpty) return b;
    if (a.endsWith('/')) return '$a$b';
    return '$a/$b';
  }

  String _baseName(String p) {
    final s = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    final i = s.lastIndexOf('/');
    return i < 0 ? s : s.substring(i + 1);
  }

  String get _parent {
    if (_cwd.isEmpty) return '';
    final s = _cwd.endsWith('/') ? _cwd.substring(0, _cwd.length - 1) : _cwd;
    final i = s.lastIndexOf('/');
    return i <= 0 ? '/' : s.substring(0, i);
  }

  /// 面包屑：从根开始逐段
  List<(String, String)> get _crumbs {
    final segs = _cwd.split('/').where((e) => e.isNotEmpty).toList();
    final out = <(String, String)>[('/', '/')];
    var acc = '';
    for (final s in segs) {
      acc = '$acc/$s';
      out.add((s, acc));
    }
    return out;
  }

  // ------------------------------------------------------------- 数据

  Future<void> _boot() async {
    final st = await SystemChannel.storage();
    if (!mounted) return;
    _storage = st;
    final start = (st != null && st.emulated.isNotEmpty)
        ? st.emulated
        : (st?.appDir ?? '/');
    _root = start;
    _cwd = start;
    await _list();
  }

  Future<void> _list() async {
    setState(() {
      _loading = true;
      _index = 0;
    });
    final out = <FileSystemEntity>[];
    String? err;
    try {
      final dir = Directory(_cwd);
      await for (final e in dir.list(followLinks: false)) {
        out.add(e);
      }
    } catch (e) {
      err = '$e';
    }
    out.sort((a, b) {
      final ad = a is Directory;
      final bd = b is Directory;
      if (ad != bd) return ad ? -1 : 1;
      return _baseName(a.path)
          .toLowerCase()
          .compareTo(_baseName(b.path).toLowerCase());
    });
    if (!mounted) return;
    setState(() {
      _items = out;
      _loading = false;
      if (err != null) {
        final needAll = _storage != null && !_storage!.allFiles;
        _status = '这个目录读不了：$_cwd\n'
            '${needAll ? '安卓 11 以上要先去系统里开「所有文件访问」，点右上角那个按钮。' : '可能没有权限，或者目录不存在。'}';
      }
    });
  }

  Future<void> _enter(String path) async {
    _cwd = path;
    await _list();
  }

  Future<void> _up() async {
    if (_cwd == _root || _cwd.isEmpty || _cwd == '/') {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    await _enter(_parent);
  }

  // ------------------------------------------------------------- 动作

  Future<void> _open(FileSystemEntity e) async {
    if (e is Directory) {
      await _enter(e.path);
      return;
    }
    final ok = await SystemChannel.openFile(e.path);
    if (!mounted) return;
    setState(() => _status = ok
        ? '已用系统应用打开：${_baseName(e.path)}'
        : '打不开「${_baseName(e.path)}」：系统没有能处理这种文件的程序');
  }

  Future<void> _actions(FileSystemEntity e) async {
    final name = _baseName(e.path);
    final isDir = e is Directory;
    final isZip = !isDir && name.toLowerCase().endsWith('.zip');

    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: TvColors.panel,
        title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'open'),
            child: const _Opt(Icons.open_in_new, '打开'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            child: const _Opt(Icons.copy_all_outlined, '复制'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'cut'),
            child: const _Opt(Icons.cut_outlined, '剪切'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'rename'),
            child: const _Opt(Icons.drive_file_rename_outline, '重命名'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'zip'),
            child: const _Opt(Icons.folder_zip_outlined, '压缩成 zip'),
          ),
          if (isZip)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'unzip'),
              child: const _Opt(Icons.unarchive_outlined, '解压到当前目录'),
            ),
          if (!isDir)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'upload'),
              child: const _Opt(Icons.cloud_upload_outlined, '上传到服务器 download'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'props'),
            child: const _Opt(Icons.info_outline, '属性'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child:
                const _Opt(Icons.delete_outline, '删除', color: TvColors.danger),
          ),
        ],
      ),
    );
    if (pick == null) {
      _node.requestFocus();
      return;
    }

    switch (pick) {
      case 'open':
        await _open(e);
        break;
      case 'copy':
        setState(() {
          _clip = [e.path];
          _clipCut = false;
          _status = '已复制「$name」，进到目标目录按「粘贴」';
        });
        break;
      case 'cut':
        setState(() {
          _clip = [e.path];
          _clipCut = true;
          _status = '已剪切「$name」，进到目标目录按「粘贴」（原文件那时才消失）';
        });
        break;
      case 'rename':
        await _rename(e);
        break;
      case 'zip':
        await _zip(e);
        break;
      case 'unzip':
        await _unzip(File(e.path));
        break;
      case 'upload':
        await _upload(File(e.path));
        break;
      case 'props':
        await _props(e);
        break;
      case 'delete':
        await _delete(e);
        break;
    }
    _node.requestFocus();
  }

  Future<void> _paste() async {
    if (_clip.isEmpty) return;
    setState(() => _status = '正在粘贴…');
    var done = 0;
    final errs = <String>[];
    for (final p in _clip) {
      final target = _join(_cwd, _baseName(p));
      if (target == p) {
        errs.add('${_baseName(p)}（就是原位置）');
        continue;
      }
      try {
        if (Directory(target).existsSync() || File(target).existsSync()) {
          errs.add('${_baseName(p)}（目标已有同名文件）');
          continue;
        }
        final isDir =
            FileSystemEntity.typeSync(p) == FileSystemEntityType.directory;
        if (_clipCut) {
          // 剪切走 rename：同一分区是瞬时的；跨分区/U 盘会抛异常，由下面兜住
          if (isDir) {
            await Directory(p).rename(target);
          } else {
            await File(p).rename(target);
          }
        } else {
          final src = isDir ? Directory(p) : File(p);
          await _copyRecursive(src, target);
        }
        done++;
      } catch (e) {
        errs.add('${_baseName(p)}（$e）');
      }
    }
    if (!mounted) return;
    setState(() {
      if (_clipCut) _clip = const [];
      _status = '粘贴完成：$done 个'
          '${errs.isEmpty ? '' : '；跳过 ${errs.join('、')}'}';
    });
    await _list();
  }

  Future<void> _copyRecursive(FileSystemEntity src, String dst) async {
    if (src is Directory) {
      await Directory(dst).create(recursive: true);
      await for (final e in src.list(followLinks: false)) {
        await _copyRecursive(e, _join(dst, _baseName(e.path)));
      }
    } else if (src is File) {
      await src.copy(dst);
    }
  }

  Future<void> _rename(FileSystemEntity e) async {
    final old = _baseName(e.path);
    final ctrl = TextEditingController(text: old);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: const Text('重命名'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || name == old) return;
    try {
      final target = _join(_cwd, name);
      if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
        setState(() => _status = '改名失败：已经有个叫「$name」的了');
        return;
      }
      if (e is Directory) {
        await e.rename(target);
      } else if (e is File) {
        await e.rename(target);
      }
      if (!mounted) return;
      setState(() => _status = '已改名为「$name」');
      await _list();
    } catch (err) {
      if (!mounted) return;
      setState(() => _status = '改名失败：$err');
    }
  }

  Future<void> _delete(FileSystemEntity e) async {
    final name = _baseName(e.path);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: Text('删除「$name」？'),
        content: Text(
          e is Directory ? '整个文件夹连同里面的东西都会删掉，删了就找不回来。' : '删了就找不回来。',
          style: const TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: TvColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await e.delete(recursive: true);
      if (!mounted) return;
      setState(() => _status = '已删除「$name」');
      await _list();
    } catch (err) {
      if (!mounted) return;
      setState(() => _status = '删不掉：$err');
    }
  }

  Future<void> _zip(FileSystemEntity e) async {
    final name = _baseName(e.path);
    final out = _join(_cwd, '$name.zip');
    setState(() => _status = '正在压缩「$name」…');
    final n = await SystemChannel.zip([e.path], out);
    if (!mounted) return;
    setState(() => _status =
        n < 0 ? '压缩失败（文件太多或没有权限）' : '已压缩：$name.zip（$n 个文件）');
    await _list();
  }

  Future<void> _unzip(File zip) async {
    final name = _baseName(zip.path);
    final stem = name.toLowerCase().endsWith('.zip')
        ? name.substring(0, name.length - 4)
        : name;
    final dir = _join(_cwd, stem);
    setState(() => _status = '正在解压「$name」…');
    final n = await SystemChannel.unzip(zip.path, dir);
    if (!mounted) return;
    setState(() => _status =
        n < 0 ? '解压失败：压缩包可能损坏或者不是 zip' : '已解压 $n 个文件到「$stem」');
    await _list();
  }

  Future<void> _upload(File f) async {
    final name = _baseName(f.path);
    if (!widget.app.connected) {
      setState(() => _status = '还没连上服务器，先去「账户」连一下再上传');
      return;
    }
    setState(() => _status = '正在上传「$name」到服务器的 download…');
    try {
      final rel = await widget.app.uploadLocal(f);
      if (!mounted) return;
      setState(() => _status = '已上传到服务器：$rel（在「工具 → 软件下载」里能看到）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '上传失败：$e');
    }
  }

  Future<void> _props(FileSystemEntity e) async {
    final name = _baseName(e.path);
    int size = 0;
    var remark = '';
    var mtime = '';
    try {
      final st = await e.stat();
      size = st.size;
      mtime = st.modified.toString().split('.').first;
      if (e is Directory) {
        remark = '文件夹（大小只是目录项本身，不是里面所有文件之和）';
      }
    } catch (_) {}
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SelectableText(
          '路径：${e.path}\n'
          '类型：${e is Directory ? '文件夹' : '文件'}\n'
          '大小：${fmtBytes(size)}\n'
          '修改时间：$mtime\n'
          '${remark.isEmpty ? '' : '\n$remark'}',
          style: const TextStyle(fontSize: 13.5, height: 1.7),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _newFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '文件夹名字'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    try {
      await Directory(_join(_cwd, name)).create();
      if (!mounted) return;
      setState(() => _status = '已创建「$name」');
      await _list();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '创建失败：$e');
    }
  }

  Future<void> _askAllFiles() async {
    await SystemChannel.requestAllFiles();
    if (!mounted) return;
    setState(() => _status = '去系统里打开「所有文件访问」再回来，就能看整机文件了');
  }

  // ------------------------------------------------------------- 按键

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final n = _items.length;

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
      if (n > 0) _actions(_items[clampInt(_index, 0, n - 1)]);
      return KeyEventResult.handled;
    }
    if (isSelect(e) || isRight(e)) {
      if (n > 0) _open(_items[clampInt(_index, 0, n - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int v) {
    if (_items.isEmpty) return;
    final next = clampInt(v, 0, _items.length - 1);
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
                text: _status.isNotEmpty ? _status : 'OK 打开 · 菜单键 操作 · ← 返回上级',
                warn: _status.contains('失败') || _status.contains('读不了'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final compact = isCompact(context);
    final fs = compact ? 12.5 : 14.0;
    final gated = _storage != null && !_storage!.allFiles;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 6 : 16, compact ? 4 : 10, compact ? 6 : 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: _up,
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回上级 / 退出',
              ),
              Expanded(
                child: Text(
                  _cwd.isEmpty ? '文件管理' : _baseName(_cwd),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: compact ? 18 : 22,
                      fontWeight: FontWeight.w700),
                ),
              ),
              if (gated)
                IconButton(
                  onPressed: _askAllFiles,
                  icon: const Icon(Icons.lock_open_rounded),
                  tooltip: '开启所有文件访问',
                ),
              IconButton(
                onPressed: _newFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: '新建文件夹',
              ),
              if (_clip.isNotEmpty)
                IconButton(
                  onPressed: _paste,
                  icon: const Icon(Icons.content_paste_go_rounded),
                  tooltip: '粘贴',
                ),
              IconButton(
                onPressed: _list,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: '刷新',
              ),
            ],
          ),
          // 面包屑（可点，手机上靠它跳回上层）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final c in _crumbs) ...[
                  GestureDetector(
                    onTap: () => _enter(c.$2),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text(
                        c.$1,
                        style: TextStyle(
                          fontSize: fs,
                          color:
                              c.$2 == _cwd ? TvColors.text : TvColors.textDim,
                          fontWeight: c.$2 == _cwd
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      size: 14, color: TvColors.textDim),
                ],
                if (_clip.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      '剪贴板：${_clip.length} 项（${_clipCut ? '剪切' : '复制'}）',
                      style:
                          const TextStyle(fontSize: 12, color: TvColors.accent),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 54, color: TvColors.textDim),
            SizedBox(height: 12),
            Text('这个文件夹是空的',
                style: TextStyle(fontSize: 16, color: TvColors.textDim)),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, c) => Center(
        child: SizedBox(
          width: c.maxWidth > 900 ? 900 : c.maxWidth,
          child: ListView.builder(
            controller: _scroll,
            padding:
                EdgeInsets.fromLTRB(pagePad(context), 4, pagePad(context), 18),
            itemCount: _items.length,
            itemBuilder: (context, i) {
              final e = _items[i];
              final isDir = e is Directory;
              final name = _baseName(e.path);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: SizedBox(
                  height: 64,
                  child: TvRow(
                    focused: _node.hasFocus && i == _index,
                    title: name,
                    subtitle: isDir ? '文件夹' : _subtitleOf(e),
                    leading: Icon(
                      isDir ? Icons.folder_rounded : _iconOf(name),
                      size: 22,
                      color: isDir ? TvColors.accent : TvColors.textDim,
                    ),
                    trailing: isDir
                        ? const Icon(Icons.chevron_right,
                            color: TvColors.textDim)
                        : null,
                    onTap: () {
                      setState(() => _index = i);
                      _node.requestFocus();
                      if (isDir) {
                        _enter(e.path);
                      } else {
                        _actions(e);
                      }
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _subtitleOf(FileSystemEntity e) {
    try {
      return fmtBytes((e as File).lengthSync());
    } catch (_) {
      return '文件';
    }
  }

  IconData _iconOf(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.apk')) return Icons.android_rounded;
    if (n.endsWith('.zip') || n.endsWith('.rar') || n.endsWith('.7z')) {
      return Icons.folder_zip_outlined;
    }
    if (n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png') ||
        n.endsWith('.webp') ||
        n.endsWith('.gif')) {
      return Icons.image_outlined;
    }
    if (n.endsWith('.mp4') ||
        n.endsWith('.mkv') ||
        n.endsWith('.avi') ||
        n.endsWith('.ts') ||
        n.endsWith('.mov')) {
      return Icons.movie_outlined;
    }
    if (n.endsWith('.mp3') ||
        n.endsWith('.flac') ||
        n.endsWith('.wav') ||
        n.endsWith('.m4a')) {
      return Icons.music_note_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

/// 操作弹窗里的一行
class _Opt extends StatelessWidget {
  const _Opt(this.icon, this.label, {this.color = TvColors.text});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon,
              size: 20,
              color: color == TvColors.text ? TvColors.textDim : color),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(fontSize: 15, color: color)),
        ],
      );
}
