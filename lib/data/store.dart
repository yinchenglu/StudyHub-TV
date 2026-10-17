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
  static const _kDensity = 'grid_density';
  static const _kSlideshow = 'slideshow_sec';
  static const _kPlayMode = 'play_mode';
  static const _kSpeed = 'play_speed';
  static const _kSkipStart = 'skip_start_sec';
  static const _kSkipEnd = 'skip_end_sec';
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

  /// 启动时默认打开哪个分区
  Section get startSection {
    final n = _p!.getString(_kStartSection);
    return Section.values.firstWhere(
      (s) => s.name == n,
      orElse: () => Section.images,
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

  /// 跳过片头：每个视频开头自动跳过多少秒（0 = 关闭）
  int get skipStartSec => _p!.getInt(_kSkipStart) ?? 0;
  Future<void> setSkipStartSec(int v) async => _p!.setInt(_kSkipStart, v < 0 ? 0 : v);

  /// 跳过片尾：离结束还有多少秒就自动下一个（0 = 关闭）
  int get skipEndSec => _p!.getInt(_kSkipEnd) ?? 0;
  Future<void> setSkipEndSec(int v) async => _p!.setInt(_kSkipEnd, v < 0 ? 0 : v);
}
