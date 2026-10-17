import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/remote/remote_source.dart';
import '../data/store.dart';
import '../data/thumb_cache.dart';

/// 全局状态。整个 App 只有一个界面，所以状态集中放这里，
/// 界面层用 AnimatedBuilder 监听，不需要引入状态管理库。
class AppState extends ChangeNotifier {
  final Store store = Store.instance;

  RemoteSource? _source;

  /// 当前连上的文件源（null = 没连上 / 没有账号）
  RemoteSource? get source => _source;
  bool get connected => _source != null;

  Account? get account => store.current;
  List<Account> get accounts => store.accounts;

  Section section = Section.images;

  /// 每个分区各自记住浏览到哪了 —— 从视频退出来再点图片，
  /// 不应该还停在上次的视频目录
  final Map<Section, String> _cwd = {};

  List<RemoteEntry> _entries = const [];
  List<RemoteEntry> get entries => _entries;

  bool loading = false;
  String? error;
  String status = '';

  bool _booting = true;
  bool get booting => _booting;

  String cwdOf(Section s) => _cwd[s] ?? '';
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

  // --------------------------------------------------------------- 浏览

  Future<void> setSection(Section s) async {
    if (section == s && _entries.isNotEmpty) return;
    section = s;
    _entries = const [];
    error = null;
    notifyListeners();
    if (s.isMedia) await refresh();
  }

  Future<void> refresh() async {
    final src = _source;
    if (src == null || !section.isMedia) return;

    loading = true;
    error = null;
    notifyListeners();

    try {
      final all = await src.list(cwd);
      final want = section.accept;
      _entries = all
          .where((e) => e.isDir || e.kind == want)
          .toList(growable: false);
    } catch (e) {
      _entries = const [];
      error = e.toString();
    }
    loading = false;
    notifyListeners();
  }

  /// 进入子目录
  Future<void> enter(String dirPath) async {
    _cwd[section] = dirPath;
    _entries = const [];
    notifyListeners();
    await refresh();
  }

  /// 返回上一级。已经在根目录则返回 false（调用方据此把焦点交回左侧菜单）
  Future<bool> up() async {
    final cur = cwd;
    if (cur.isEmpty) return false;
    final i = cur.lastIndexOf('/');
    _cwd[section] = i < 0 ? '' : cur.substring(0, i);
    _entries = const [];
    notifyListeners();
    await refresh();
    return true;
  }

  /// 面包屑跳转到某一层（0 = 根）
  Future<void> jumpToDepth(int depth) async {
    final segs = cwd.split('/').where((e) => e.isNotEmpty).toList();
    if (depth <= 0) {
      _cwd[section] = '';
    } else {
      _cwd[section] = segs.take(depth).join('/');
    }
    _entries = const [];
    notifyListeners();
    await refresh();
  }

  /// 面包屑文字：根 / 电影 / 2024
  List<String> get crumbs {
    final segs = cwd.split('/').where((e) => e.isNotEmpty).toList();
    return [account?.root.isEmpty ?? true ? '根目录' : account!.root, ...segs];
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
