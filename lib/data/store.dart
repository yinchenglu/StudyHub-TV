import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
/// 本地存储：账号列表 + 密码 + 一坨设置项。
///
/// 密码为什么不跟账号一起存 SharedPreferences：
/// SharedPreferences 是明文 XML，任何能读到应用目录的程序（含 root 后的自己）
/// 都能直接看。安卓上 flutter_secure_storage 走 Keystore 加密，
/// 系统里其它应用解不开。
///
/// 但电视盒子有个坑：部分廉价盒子的 Keystore 实现有问题（尤其是
/// 刷了非官方固件的），调用会直接抛异常。所以下面所有加解密调用
/// 都包了 try/catch —— 失败就退回普通存储，**宁可安全性降一点，
/// 也不能让用户"账号存不上、每次开机重新填"**。
class Store {
  Store._();
  static final Store instance = Store._();

  static const _kAccounts = 'accounts_v1';
  static const _kCurrent = 'current_account_v1';
  static const _kThumbWidth = 'thumb_width';
  static const _kShowNames = 'show_names';
  static const _kAutoNext = 'auto_next';
  static const _kStartSection = 'start_section';
  static const _kStartMigrated = 'start_section_v17';
  static const _kDensity = 'grid_density';
  static const _kSlideshow = 'slideshow_sec';
  static const _kPlayMode = 'play_mode';
  static const _kSpeed = 'play_speed';
  static const _kSkipMap = 'skip_by_dir_v1';
  static const _kHwDecode = 'hw_decode';
  static const _kDownloadDir = 'download_dir';
  static const _kPwdPrefix = 'pwd_';

  final _secure = const FlutterSecureStorage();
  SharedPreferences? _p;

  List<Account> _accounts = [];
  String? _currentId;

  List<Account> get accounts => List.unmodifiable(_accounts);
  String? get currentId => _currentId;

  Account? get current {
    if (_accounts.isEmpty) return null;
    for (final a in _accounts) {
      if (a.id == _currentId) return a;
    }
    return _accounts.first;
  }

  Future<void> init() async {
    _p ??= await SharedPreferences.getInstance();
    _currentId = _p!.getString(_kCurrent);

    final raw = _p!.getString(_kAccounts);
    final list = <Account>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final arr = jsonDecode(raw);
        if (arr is List) {
          for (final e in arr) {
            if (e is Map<String, dynamic>) {
              final a = Account.fromJson(e);
              list.add(a.copyWith(password: await _readPwd(a.id)));
            }
          }
        }
      } catch (e) {
        debugPrint('账号列表解析失败：$e');
      }
    }
    _accounts = list;
    if (_currentId != null && !_accounts.any((a) => a.id == _currentId)) {
      _currentId = _accounts.isEmpty ? null : _accounts.first.id;
    }

    // v1.7 一次性迁移：老版本默认进「图片」，升级后不改就还是一开就进图片。
    // 用户要求默认改成「视频」，所以在第一次跑新版时把值统一成视频，
    // 之后用户在设置里改了就当用户的选择，不再覆盖。
    if (_p!.getBool(_kStartMigrated) != true) {
      await _p!.setString(_kStartSection, Section.videos.name);
      await _p!.setBool(_kStartMigrated, true);
    }
  }

  // ------------------------------------------------------------- 密码

  Future<String> _readPwd(String id) async {
    try {
      final v = await _secure.read(key: '$_kPwdPrefix$id');
      if (v != null) return v;
    } catch (e) {
      debugPrint('安全存储读取失败，改用普通存储：$e');
    }
    return _p!.getString('$_kPwdPrefix$id') ?? '';
  }

  Future<void> _writePwd(String id, String pwd) async {
    try {
      await _secure.write(key: '$_kPwdPrefix$id', value: pwd);
      // 保险：安全存储成功时把明文残留清掉
      await _p!.remove('$_kPwdPrefix$id');
      return;
    } catch (e) {
      debugPrint('安全存储写入失败，改用普通存储：$e');
    }
    await _p!.setString('$_kPwdPrefix$id', pwd);
  }

  Future<void> _deletePwd(String id) async {
    try {
      await _secure.delete(key: '$_kPwdPrefix$id');
    } catch (_) {}
    await _p!.remove('$_kPwdPrefix$id');
  }

  // ------------------------------------------------------------- 账号

  Future<void> saveAccount(Account a) async {
    final i = _accounts.indexWhere((e) => e.id == a.id);
    if (i >= 0) {
      _accounts[i] = a;
    } else {
      _accounts.add(a);
    }
    _currentId ??= a.id;
    await _writePwd(a.id, a.password);
    await _flush();
  }

  Future<void> deleteAccount(String id) async {
    _accounts.removeWhere((a) => a.id == id);
    if (_currentId == id) {
      _currentId = _accounts.isEmpty ? null : _accounts.first.id;
    }
    await _deletePwd(id);
    await _flush();
  }

  Future<void> setCurrent(String id) async {
    _currentId = id;
    await _p!.setString(_kCurrent, id);
  }

  Future<void> _flush() async {
    final list = _accounts.map((a) => a.toJson()).toList();
    await _p!.setString(_kAccounts, jsonEncode(list));
    if (_currentId != null) await _p!.setString(_kCurrent, _currentId!);
  }

  // ------------------------------------------------------------- 设置

  /// 缩略图宽度（像素）。320 省内存、480 更清晰、720 大图党用。
  int get thumbWidth => _p!.getInt(_kThumbWidth) ?? 480;
  Future<void> setThumbWidth(int v) async => _p!.setInt(_kThumbWidth, v);

  /// 卡片下面显不显示文件名
  bool get showNames => _p!.getBool(_kShowNames) ?? true;
  Future<void> setShowNames(bool v) async => _p!.setBool(_kShowNames, v);

  /// 视频播完自动下一个
  bool get autoNext => _p!.getBool(_kAutoNext) ?? true;
  Future<void> setAutoNext(bool v) async => _p!.setBool(_kAutoNext, v);

  /// 启动时默认打开哪个分区。
  /// v1.7：默认从「图片」改成「视频」—— 用户主要拿它看剧，
  /// 开机直接落到视频列表少按一次键。设置里改过的仍以设置为准。
  Section get startSection {
    final n = _p!.getString(_kStartSection);
    return Section.values.firstWhere(
      (s) => s.name == n,
      orElse: () => Section.videos,
    );
  }

  Future<void> setStartSection(Section s) async =>
      _p!.setString(_kStartSection, s.name);

  /// 网格密度：0 大卡片 / 1 中 / 2 小
  int get density => _p!.getInt(_kDensity) ?? 1;
  Future<void> setDensity(int v) async => _p!.setInt(_kDensity, v);

  /// 图片幻灯片播放间隔（秒），0 = 关闭
  int get slideshowSec => _p!.getInt(_kSlideshow) ?? 0;
  Future<void> setSlideshowSec(int v) async => _p!.setInt(_kSlideshow, v);

  // ------------------------------------------------------------- 播放器

  /// 播放模式（见 models.dart 的 PlayMode）
  PlayMode get playMode => PlayMode.fromIndex(_p!.getInt(_kPlayMode) ?? 0);
  Future<void> setPlayMode(PlayMode m) async => _p!.setInt(_kPlayMode, m.index);

  /// 倍速。存成 double，0.25 步进，范围 0.5–3.0
  double get speed {
    final v = _p!.getDouble(_kSpeed) ?? 1.0;
    return v <= 0 ? 1.0 : v;
  }

  Future<void> setSpeed(double v) async => _p!.setDouble(_kSpeed, v);

  // ------------------------------------------------------------- 跳过片头片尾
  //
  // v1.6 改成**按目录**记：同一个文件夹里的剧集共用一套片头片尾，
  // 换个目录（另一部剧 / 另一季）就不该沿用。所以键是"目录的相对路径"。
  //
  // 存成一个 JSON map 而不是给每个目录开一个键：
  //   SharedPreferences 的键一多，初始化时全量读进内存很浪费；
  //   这里条目最多几十个，一个字符串最省事。
  //   {"StudyHub-TV/video/某剧": {"s": 95, "e": 120}, ...}

  Map<String, Map<String, int>> _skipCache = {};
  bool _skipLoaded = false;

  Map<String, Map<String, int>> get _skipMap {
    if (!_skipLoaded) {
      _skipLoaded = true;
      final raw = _p!.getString(_kSkipMap);
      if (raw != null && raw.isNotEmpty) {
        try {
          final m = jsonDecode(raw);
          if (m is Map) {
            final out = <String, Map<String, int>>{};
            m.forEach((k, v) {
              if (v is Map) {
                out['$k'] = {
                  's': (v['s'] as num?)?.toInt() ?? 0,
                  'e': (v['e'] as num?)?.toInt() ?? 0,
                };
              }
            });
            _skipCache = out;
          }
        } catch (e) {
          debugPrint('跳过片头片尾记录解析失败：$e');
        }
      }
    }
    return _skipCache;
  }

  Future<void> _flushSkip() async =>
      _p!.setString(_kSkipMap, jsonEncode(_skipMap));

  /// 某个目录的「跳过片头」秒数（0 = 没设）
  int skipStartOf(String dir) {
    final v = _skipMap[dir];
    final s = v?['s'] ?? 0;
    return s < 0 ? 0 : s;
  }

  /// 某个目录的「跳过片尾」秒数（0 = 没设）
  int skipEndOf(String dir) {
    final v = _skipMap[dir];
    final e = v?['e'] ?? 0;
    return e < 0 ? 0 : e;
  }

  Future<void> setSkipOf(String dir, {int? start, int? end}) async {
    if (dir.isEmpty) return;
    final cur = Map<String, int>.from(_skipMap[dir] ?? const {});
    if (start != null) cur['s'] = start < 0 ? 0 : start;
    if (end != null) cur['e'] = end < 0 ? 0 : end;
    if ((cur['s'] ?? 0) <= 0 && (cur['e'] ?? 0) <= 0) {
      _skipMap.remove(dir);
    } else {
      _skipMap[dir] = cur;
    }
    await _flushSkip();
  }

  /// 有设置了跳过片头/片尾的目录数（设置页展示用）
  int get skipDirCount => _skipMap.length;

  Future<void> clearAllSkip() async {
    _skipMap.clear();
    await _flushSkip();
  }

  // ------------------------------------------------------------- 播放器其它

  /// 视频硬解：true = 交给电视自带的解码器（省电、不卡），false = 软解（兼容性最好）
  bool get hwDecode => _p!.getBool(_kHwDecode) ?? true;
  Future<void> setHwDecode(bool v) async => _p!.setBool(_kHwDecode, v);

  // ------------------------------------------------------------- 下载位置

  /// 「软件下载」把文件存到哪。
  /// 空字符串 = 默认的应用专属目录（不需要任何存储权限，最稳）。
  String get downloadDir => _p!.getString(_kDownloadDir) ?? '';
  Future<void> setDownloadDir(String v) async =>
      _p!.setString(_kDownloadDir, v.trim());
}
