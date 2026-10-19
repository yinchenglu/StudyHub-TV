import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../data/models.dart';
import '../data/remote/remote_source.dart';
import '../data/store.dart';
import '../data/thumb_cache.dart';

/// 全局状态。整个 App 只有一个界面，所以状态集中放这里，
/// 界面层用 AnimatedBuilder 监听，不需要引入状态管理库。
///
/// v1.2 起多了一层「媒体库根目录」的概念：
///   账号根目录
///     └── StudyHub-TV/          ← 自动识别（名字大小写、写法都有容错）
///           ├── image/          ← 「图片」分区直接落在这里
///           ├── video/          ← 「视频」
///           ├── audio/          ← 「音频」
///           └── download/       ← 工具 → 下载工作
/// 用户不需要在账号里填这些路径，连上之后自动找。
/// 找不到（比如人家根本没按这个结构建目录）就退回"整个账号根目录"照旧浏览。
class AppState extends ChangeNotifier {
  final Store store = Store.instance;

  RemoteSource? _source;

  /// 当前连上的文件源（null = 没连上 / 没有账号）
  RemoteSource? get source => _source;
  bool get connected => _source != null;

  Account? get account => store.current;
  List<Account> get accounts => store.accounts;

  Section section = Section.accounts;

  /// 每个分区各自的「根」（相对账号根目录的绝对路径）
  final Map<Section, String> _base = {};

  String baseOf(Section s) => _base[s] ?? '';
  String get currentBase => baseOf(section);

  /// 自动识别到的 StudyHub-TV 目录（空 = 没找到，退回账号根目录）
  String libraryRoot = '';

  /// 每个分区各自记住浏览到哪了 —— 从视频退出来再点图片，
  /// 不应该还停在上次的视频目录
  final Map<Section, String> _cwd = {};

  List<RemoteEntry> _entries = const [];
  List<RemoteEntry> get entries => _entries;

  /// 目录缓存：key = "分区|路径"。
  ///
  /// 为什么要有它：以前每次切分区都会先把列表清空再发请求，
  /// 电视上就是"按一下 → 画面空一下 → 一两秒后才有内容"，
  /// 用户体感就是卡。现在切回来时先用上次的结果立刻画出来，
  /// 再在后台悄悄刷新，没有变化的话用户完全无感。
  final Map<String, List<RemoteEntry>> _cache = {};

  String _cacheKey(Section s, String path) => '${s.name}|$path';

  List<RemoteEntry>? _cached(Section s, String path) => _cache[_cacheKey(s, path)];

  /// 立刻把缓存的内容显示出来（没有就不动）
  void _showCached(Section s, String path) {
    final hit = _cached(s, path);
    if (hit != null) _entries = hit;
  }

  bool loading = false;
  String? error;
  String status = '';

  /// 面板级「返回键」拦截：例如账户面板正在填表单时，返回键应该先退回列表，
  /// 而不是把焦点弹到左侧菜单。返回 true = 已消费这次返回。
  bool Function()? backHandler;

  /// 谁挂的拦截器（避免 A 面板销毁时把 B 面板的拦截器清掉）
  Object? backOwner;

  bool _booting = true;
  bool get booting => _booting;

  String cwdOf(Section s) => _cwd[s] ?? baseOf(s);
  String get cwd => cwdOf(section);

  // --------------------------------------------------------------- 启动

  Future<void> boot() async {
    await store.init();
    section = store.startSection;
    _booting = false;
    notifyListeners();
    await connectCurrent();
  }

  /// 连接当前账号
  Future<void> connectCurrent() async {
    final acc = store.current;
    await _source?.dispose();
    _source = null;
    _entries = const [];
    _cache.clear();
    _base.clear();
    _cwd.clear();
    libraryRoot = '';
    error = null;

    if (acc == null) {
      loading = false;
      notifyListeners();
      return;
    }

    loading = true;
    status = '正在连接 ${acc.name}…';
    notifyListeners();

    try {
      _source = await RemoteSource.open(acc);
      // 连上之后先认目录：这一步失败不算致命（大不了按账号根目录浏览），
      // 所以内部全部 try/catch 兜住，绝不让它把「已连接」变成「连接失败」
      await _detectLibrary();
      status = '';
      loading = false;
      notifyListeners();
      if (section.isMedia) await refresh();
    } catch (e) {
      error = e.toString();
      status = '';
      loading = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------- 自动识别目录

  static String _join(String a, String b) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a/$b';
  }

  /// 在 [parent] 下按候选名找一个子目录，找不到返回 null
  static RemoteEntry? _pickDir(List<RemoteEntry> list, Set<String> names) {
    RemoteEntry? loose;
    for (final e in list) {
      if (!e.isDir) continue;
      final n = e.name.trim().toLowerCase();
      if (names.contains(n)) return e;
      // 退一步：「图片 2024」「videos-旧」这类也算，只在没有精确匹配时用
      for (final cand in names) {
        if (n.startsWith(cand)) {
          loose ??= e;
          break;
        }
      }
    }
    return loose;
  }

  Future<List<RemoteEntry>> _safeList(String rel) async {
    final src = _source;
    if (src == null) return const [];
    try {
      return await src.list(rel);
    } catch (e) {
      debugPrint('列目录失败（$rel）：$e');
      return const [];
    }
  }

  /// 识别 StudyHub-TV / image / video / audio / download
  Future<void> _detectLibrary() async {
    _base.clear();

    // 1) 账号根目录里找 StudyHub-TV
    final root = await _safeList('');
    final lib = _pickDir(root, kLibraryDirNames)?.path ?? '';

    // 2) 账号根目录本身就是媒体库（用户直接把共享指到了 StudyHub-TV）
    final libEntries = lib.isEmpty ? root : await _safeList(lib);
    final hasImage = _pickDir(libEntries, kImageDirNames) != null;
    final hasVideo = _pickDir(libEntries, kVideoDirNames) != null;
    final hasAudio = _pickDir(libEntries, kAudioDirNames) != null;

    if (lib.isEmpty && !hasImage && !hasVideo && !hasAudio) {
      // 既没 StudyHub-TV、根目录也不像媒体库 → 退回根目录照旧浏览
      libraryRoot = '';
      _base[Section.tools] = 'download';
      return;
    }
    libraryRoot = lib;

    // 3) 三个分区各自的目录名。
    //    认得出就进对应子目录；认不出（比如只建了 video，没建 image）
    //    就退回媒体库根目录 —— 反正列表会按后缀过滤，
    //    总比直接报「目录不存在」让用户以为坏了强。
    String resolve(Set<String> names) => _pickDir(libEntries, names)?.path ?? lib;

    _base[Section.images] = resolve(kImageDirNames);
    _base[Section.videos] = resolve(kVideoDirNames);
    _base[Section.audio] = resolve(kAudioDirNames);

    // 4) 下载目录（工具里用）。这个必须真实存在才有意义，
    //    认不到就按约定名猜，下载页会用一句人话提示"去建个 download 文件夹"
    _base[Section.tools] =
        _pickDir(libEntries, kDownloadDirNames)?.path ?? _join(lib, 'download');
  }

  /// 「工具 → 下载工作」要看的目录
  String get downloadBase => baseOf(Section.tools);

  // --------------------------------------------------------------- 浏览

  Future<void> setSection(Section s) async {
    if (section == s && _entries.isNotEmpty) return;
    section = s;
    error = null;
    // 先上缓存：切回"视频"时立刻看到上次的剧集列表，不用等网络
    _showCached(s, cwdOf(s));
    if (s.isMedia && _entries.isEmpty) _entries = const [];
    notifyListeners();
    if (s.isMedia) await refresh();
  }

  Future<void> refresh() async {
    final src = _source;
    if (src == null || !section.isMedia) return;

    final sec = section;
    final path = cwd;
    loading = true;
    error = null;
    notifyListeners();

    try {
      final all = await src.list(path);
      final want = sec.accept;
      final list = all
          .where((e) => e.isDir || e.kind == want)
          .toList(growable: false);
      // 请求回来时用户可能已经切走了：只更新对应分区，别覆盖别人
      _cache[_cacheKey(sec, path)] = list;
      if (section == sec && cwd == path) _entries = list;
    } catch (e) {
      if (section == sec && cwd == path) {
        if (_entries.isEmpty) error = _describeListError(e);
      }
    }
    if (section == sec && cwd == path) loading = false;
    notifyListeners();
  }

  /// 空目录 / 目录不存在时给人看的提示要区分开：
  /// 「StudyHub-TV/image 不存在」是最常见的第一次使用问题，得说清楚。
  String _describeListError(Object e) {
    final base = baseOf(section);
    final msg = e.toString();
    if (msg.contains('404') && cwd == base && base.isNotEmpty) {
      return '$msg\n\n这个目录没找到：$base\n'
          '请在服务器上按这个结构建目录：\n'
          'StudyHub-TV/image、StudyHub-TV/video、StudyHub-TV/audio';
    }
    return msg;
  }

  /// 进入子目录
  Future<void> enter(String dirPath) async {
    _cwd[section] = dirPath;
    _showCached(section, dirPath);
    if (_entries.isEmpty) _entries = const [];
    notifyListeners();
    await refresh();
  }

  /// 返回上一级。已经在分区根目录则返回 false（调用方据此把焦点交回左侧菜单）
  Future<bool> up() async {
    final cur = cwd;
    final base = baseOf(section);
    if (cur.isEmpty) return false;
    if (base.isNotEmpty && cur == base) return false;

    final i = cur.lastIndexOf('/');
    var parent = i < 0 ? '' : cur.substring(0, i);
    // 不许退回分区根目录之上（不然「图片」能逛到视频目录里去）
    if (base.isNotEmpty && !(parent == base || parent.startsWith('$base/'))) {
      parent = base;
    }
    if (parent == cur) return false;

    _cwd[section] = parent;
    _showCached(section, parent);
    if (_entries.isEmpty) _entries = const [];
    notifyListeners();
    await refresh();
    return true;
  }

  /// 面包屑跳转到某一层（0 = 分区根目录）
  Future<void> jumpToDepth(int depth) async {
    final base = baseOf(section);
    final rel = _relToBase(cwd);
    final segs = rel.split('/').where((e) => e.isNotEmpty).toList();
    _cwd[section] =
        depth <= 0 ? base : _join(base, segs.take(depth).join('/'));
    _showCached(section, _cwd[section] ?? base);
    if (_entries.isEmpty) _entries = const [];
    notifyListeners();
    await refresh();
  }

  String _relToBase(String path) {
    final base = baseOf(section);
    if (base.isEmpty) return path;
    if (path == base) return '';
    if (path.startsWith('$base/')) return path.substring(base.length + 1);
    return path;
  }

  /// 面包屑文字：图片 / 2024 / 春节
  List<String> get crumbs {
    final rel = _relToBase(cwd);
    final segs = rel.split('/').where((e) => e.isNotEmpty).toList();
    final root = baseOf(section).isEmpty ? '根目录' : section.label;
    return [root, ...segs];
  }

  /// 分区根目录的完整路径（账号里可能配了 root 前缀，这里只做展示用）
  String get baseDisplay {
    final b = baseOf(section);
    return b.isEmpty ? '账号根目录' : b;
  }

  /// 拿一个文件的可访问地址
  MediaRef ref(String path) {
    final src = _source;
    if (src == null) throw RemoteException('还没连上服务器');
    return src.ref(path);
  }

  /// 缩略图缓存 key：带上账号 id，换服务器不会串图
  String thumbKey(String path) => '${account?.id ?? 'none'}|$path';

  void setStatus(String s) {
    status = s;
    notifyListeners();
  }

  /// 给「下载工作」用：列任意目录（不复用分区状态，避免把浏览位置搞乱）
  Future<List<RemoteEntry>> listPath(String path) async {
    final src = _source;
    if (src == null) throw RemoteException('还没连上服务器');
    return src.list(path);
  }

  /// 把电视本地的一个文件传到服务器的 download 目录。
  ///
  /// 只支持 WebDAV（SMB 的写支持不完整）；返回传上去之后的远端相对路径。
  Future<String> uploadLocal(File local) async {
    final src = _source;
    if (src == null) throw RemoteException('还没连上服务器，先去「账户」连一下');
    final name = local.path.split(Platform.pathSeparator).last;
    final dir = downloadBase;
    final rel = dir.isEmpty ? name : '$dir/$name';
    await src.put(rel, local);
    return rel;
  }

  // --------------------------------------------------------------- 账号

  Future<void> switchAccount(String id) async {
    await store.setCurrent(id);
    await connectCurrent();
  }

  Future<void> saveAccount(Account a) async {
    await store.saveAccount(a);
    if (store.currentId == null || store.current?.id == a.id) {
      await connectCurrent();
    } else {
      notifyListeners();
    }
  }

  Future<void> deleteAccount(String id) async {
    final wasCurrent = store.current?.id == id;
    await store.deleteAccount(id);
    if (wasCurrent) {
      await connectCurrent();
    } else {
      notifyListeners();
    }
  }

  // --------------------------------------------------------------- 设置

  Future<void> updateSetting(Future<void> Function() action) async {
    await action();
    notifyListeners();
  }

  Future<void> clearThumbs() async {
    await ThumbCache.instance.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _source?.dispose();
    super.dispose();
  }
}
