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

/// 一个条目（列目录时顺手把大小算好，避免每次重建都做一次同步 IO）
class _Node {
  _Node({
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
  });

  final String path;
  final String name;
  final bool isDir;
  final int size;

  FileSystemEntity get entity => isDir ? Directory(path) : File(path);
}

/// 「工具 → 文件管理」。
///
/// 能干什么：
///   浏览整台电视的存储（不是只有 App 自己的目录）、进/退目录、
///   打开文件、复制 / 剪切 / 粘贴、重命名、删除、压缩成 zip、解压 zip、
///   新建文件夹、上传到服务器的 download 目录。
///
/// v1.6 把列表改成**平铺网格**（用户要求）：电视上横向空间多、纵向少，
/// 一屏能看 20+ 个条目比只能看 8 行强得多；遥控器二维移动也更顺手。
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
  List<_Node> _items = const [];
  bool _loading = true;
  int _index = 0;
  int _cols = 4;
  double _tileH = 120;
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
    final out = <_Node>[];
    String? err;
    try {
      final dir = Directory(_cwd);
      await for (final e in dir.list(followLinks: false)) {
        final isDir = e is Directory;
        var size = 0;
        if (!isDir) {
          try {
            size = await (e as File).length();
          } catch (_) {
            size = 0;
          }
        }
        out.add(_Node(
          path: e.path,
          name: _baseName(e.path),
          isDir: isDir,
          size: size,
        ));
      }
    } catch (e) {
      err = '$e';
    }
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    if (!mounted) return;
    setState(() {
      _items = out;
      _loading = false;
      if (err != null) {
        final needAll = _storage != null && !_storage!.allFiles;
        _status = '这个目录读不了：$_cwd\n'
            '${needAll ? '安卓 11 以上要先去系统里开「所有文件访问」，点右上角那个按钮。' : '可能没有权限，或者目录不存在。'}';
      } else {
        _status = '';
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

  Future<void> _open(_Node n) async {
    if (n.isDir) {
      await _enter(n.path);
      return;
    }
    final ok = await SystemChannel.openFile(n.path);
    if (!mounted) return;
    setState(() => _status = ok
        ? '已用系统应用打开：${n.name}'
        : '打不开「${n.name}」：系统没有能处理这种文件的程序');
  }

  Future<void> _actions(_Node n) async {
    final isZip = !n.isDir && n.name.toLowerCase().endsWith('.zip');

    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: TvColors.panel,
        title: Text(n.name, maxLines: 2, overflow: TextOverflow.ellipsis),
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
          if (!n.isDir)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'upload'),
              child:
                  const _Opt(Icons.cloud_upload_outlined, '上传到服务器 download'),
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
        await _open(n);
        break;
      case 'copy':
        setState(() {
          _clip = [n.path];
          _clipCut = false;
          _status = '已复制「${n.name}」，进到目标目录按「粘贴」';
        });
        break;
      case 'cut':
        setState(() {
          _clip = [n.path];
          _clipCut = true;
          _status = '已剪切「${n.name}」，进到目标目录按「粘贴」（原文件那时才消失）';
        });
        break;
      case 'rename':
        await _rename(n);
        break;
      case 'zip':
        await _zip(n);
        break;
      case 'unzip':
        await _unzip(File(n.path));
        break;
      case 'upload':
        await _upload(File(n.path));
        break;
      case 'props':
        await _props(n);
        break;
      case 'delete':
        await _delete(n);
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

  Future<void> _rename(_Node n) async {
    final old = n.name;
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
      if (n.isDir) {
        await Directory(n.path).rename(target);
      } else {
        await File(n.path).rename(target);
      }
      if (!mounted) return;
      setState(() => _status = '已改名为「$name」');
      await _list();
    } catch (err) {
      if (!mounted) return;
      setState(() => _status = '改名失败：$err');
    }
  }

  Future<void> _delete(_Node n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: Text('删除「${n.name}」？'),
        content: Text(
          n.isDir ? '整个文件夹连同里面的东西都会删掉，删了就找不回来。' : '删了就找不回来。',
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
      await n.entity.delete(recursive: true);
      if (!mounted) return;
      setState(() => _status = '已删除「${n.name}」');
      await _list();
    } catch (err) {
      if (!mounted) return;
      setState(() => _status = '删不掉：$err');
    }
  }

  Future<void> _zip(_Node n) async {
    final out = _join(_cwd, '${n.name}.zip');
    setState(() => _status = '正在压缩「${n.name}」…');
    final count = await SystemChannel.zip([n.path], out);
    if (!mounted) return;
    setState(() => _status = count < 0
        ? '压缩失败（文件太多或没有权限）'
        : '已压缩：${n.name}.zip（$count 个文件）');
    await _list();
  }

  Future<void> _unzip(File zip) async {
    final name = _baseName(zip.path);
    final stem = name.toLowerCase().endsWith('.zip')
        ? name.substring(0, name.length - 4)
        : name;
    final dir = _join(_cwd, stem);
    setState(() => _status = '正在解压「$name」…');
    final count = await SystemChannel.unzip(zip.path, dir);
    if (!mounted) return;
    setState(() => _status = count < 0
        ? '解压失败：压缩包可能损坏或者不是 zip'
        : '已解压 $count 个文件到「$stem」');
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

  Future<void> _props(_Node n) async {
    var remark = '';
    var mtime = '';
    try {
      final st = await n.entity.stat();
      mtime = st.modified.toString().split('.').first;
      if (n.isDir) {
        remark = '文件夹（大小只是目录项本身，不是里面所有文件之和）';
      }
    } catch (_) {}
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: Text(n.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SelectableText(
          '路径：${n.path}\n'
          '类型：${n.isDir ? '文件夹' : '文件'}\n'
          '大小：${fmtBytes(n.size)}\n'
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

    // 平铺网格：上下按行跳，左右按格跳
    if (isUp(e)) {
      _move(_index - _cols);
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      _move(_index + _cols);
      return KeyEventResult.handled;
    }
    if (isLeft(e)) {
      // 第一列再按左 = 回上级目录（电视上的习惯）
      if (_index % _cols == 0) {
        _up();
      } else {
        _move(_index - 1);
      }
      return KeyEventResult.handled;
    }
    if (isRight(e)) {
      _move(_index + 1);
      return KeyEventResult.handled;
    }
    if (isMenu(e)) {
      if (n > 0) _actions(_items[clampInt(_index, 0, n - 1)]);
      return KeyEventResult.handled;
    }
    if (isSelect(e)) {
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
    _ensureVisible();
  }

  void _ensureVisible() {
    if (!_scroll.hasClients || _cols <= 0) return;
    final row = _index ~/ _cols;
    const gap = 10.0;
    final top = row * (_tileH + gap);
    final vp = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _tileH > _scroll.offset + vp) {
      _scroll.jumpTo(top + _tileH - vp + gap);
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
                    : 'OK 打开 · 菜单键 操作 · 方向键移动 · ← 第一列=返回上级',
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
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

    final compact = isCompact(context);
    return LayoutBuilder(
      builder: (context, c) {
        // 平铺列数：按可用宽度算，保证每格不少于 ~150dp（名字看得清）
        final minW = compact ? 118.0 : 158.0;
        final cols = clampInt((c.maxWidth / minW).floor(), 2, 8);
        _cols = cols;
        const gap = 10.0;
        final w =
            (c.maxWidth - pagePad(context) * 2 - gap * (cols - 1)) / cols;
        _tileH = w * (compact ? 1.0 : 0.92);

        if (_index >= _items.length) _index = _items.length - 1;

        return GridView.builder(
          controller: _scroll,
          padding:
              EdgeInsets.fromLTRB(pagePad(context), 4, pagePad(context), 18),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            mainAxisExtent: _tileH,
          ),
          itemCount: _items.length,
          itemBuilder: (context, i) {
            final n = _items[i];
            return FocusFrame(
              focused: _node.hasFocus && i == _index,
              radius: 12,
              color: TvColors.card,
              padding: const EdgeInsets.all(8),
              onTap: () {
                setState(() => _index = i);
                _node.requestFocus();
                if (n.isDir) {
                  _enter(n.path);
                } else {
                  _actions(n);
                }
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Center(
                      child: Icon(
                        n.isDir ? Icons.folder_rounded : _iconOf(n.name),
                        size: compact ? 40 : 52,
                        color:
                            n.isDir ? const Color(0xFFE8B84B) : TvColors.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    n.name,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 12 : 13.5,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: TvColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    n.isDir ? '文件夹' : fmtBytes(n.size),
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 10.5, color: TvColors.textDim),
                  ),
                  const SizedBox(height: 2),
                ],
              ),
            );
          },
        );
      },
    );
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
