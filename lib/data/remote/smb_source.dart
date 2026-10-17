import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:smb_connect/smb_connect.dart';

import '../../core/fmt.dart';
import '../models.dart';
import 'bridge_server.dart';
import 'remote_source.dart';

/// SMB / CIFS 实现。
///
/// 用的是纯 Dart 的 smb_connect（SMB 1.0 / 2.0 / 2.1），不用任何原生库 ——
/// 这样 CI 里不需要额外的 NDK 配置，也避开了"原生库和 Flutter 版本对不上"
/// 这类最难查的构建问题（StudyHub 在 media_kit 上踩过一次，记忆犹新）。
///
/// 代价：
///   * 协议上限是 SMB 2.1。服务器如果强制只允许 SMB 3，会连不上。
///     群晖 / 威联通 / Windows 默认都向下兼容 SMB2，一般没问题；
///     真遇到连不上，去服务器把「最小 SMB 协议」调到 SMB2。
///   * 播放走本地中转（见 bridge_server.dart），比 WebDAV 多一次内存拷贝。
///     实测千兆内网 4K 原盘够用；如果是百兆网，本来也放不动 4K。
class SmbSource implements RemoteSource {
  @override
  final Account account;

  SmbConnect? _conn;
  SmbBridge? _bridge;

  /// 路径 → SmbFile 缓存。列一次目录就有几百个条目，
  /// 播放时按路径取文件信息不该再发一次网络请求。
  final Map<String, SmbFile> _files = {};

  SmbSource(this.account);

  List<String> get _rootSegs =>
      account.root.split('/').where((e) => e.trim().isNotEmpty).toList();

  /// 相对路径 → SMB 绝对路径（不带结尾斜杠）
  String _abs(String rel) {
    final segs = <String>[
      ..._rootSegs,
      ...rel.split('/').where((e) => e.isNotEmpty),
    ];
    return '/${segs.join('/')}';
  }

  /// 绝对路径 → 相对账号根目录的路径
  String _rel(String abs) {
    final segs = abs.split('/').where((e) => e.isNotEmpty).toList();
    final root = _rootSegs;
    if (root.isNotEmpty && segs.length >= root.length) {
      var match = true;
      for (var i = 0; i < root.length; i++) {
        if (segs[i] != root[i]) {
          match = false;
          break;
        }
      }
      if (match) segs.removeRange(0, root.length);
    }
    return segs.join('/');
  }

  // ------------------------------------------------------------- 连接

  Future<void> connect() async {
    final raw = account.addr
        .trim()
        .replaceAll(RegExp(r'^smb://', caseSensitive: false), '')
        .replaceAll(RegExp(r'/+$'), '');
    final host = raw.split('/').first;
    if (host.isEmpty) {
      throw RemoteException('SMB 地址没填：应该是服务器 IP，例如 192.168.1.10');
    }
    final port = account.port <= 0 ? 445 : account.port;

    try {
      _conn = await SmbConnect.connectAuth(
        // smb_connect 的 host 参数不支持自定义端口写法，端口不等于 445 时
        // 直接拼在主机名后面（库内部按 "host:port" 解析）
        host: port == 445 ? host : '$host:$port',
        domain: account.domain,
        username: account.user,
        password: account.password,
      );
    } catch (e) {
      throw RemoteException(_friendly(e));
    }

    _bridge = SmbBridge(_conn!, _fileOf);
    await _bridge!.start();

    // 连上之后立刻列一次根目录，这样"密码错"这类问题在保存账号时就能发现，
    // 而不是等用户点进图片分区才报错。
    // 半路失败要把自己清理干净 —— 上层拿到的是异常，不会替我们 dispose。
    try {
      await list('');
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<SmbFile> _fileOf(String abs) async {
    final cached = _files[abs];
    if (cached != null && cached.isExists) return cached;
    final f = await _conn!.file(abs);
    _files[abs] = f;
    return f;
  }

  // ------------------------------------------------------------- 列目录

  @override
  Future<List<RemoteEntry>> list(String rel) async {
    final conn = _conn;
    if (conn == null) throw RemoteException('SMB 还没连上');

    final dirAbs = '${_abs(rel)}/'.replaceAll(RegExp(r'/{2,}'), '/');
    List<SmbFile> raw;
    try {
      final dir = await conn.file(dirAbs);
      _files[_abs(rel)] = dir;
      raw = await conn.listFiles(dir);
    } catch (e) {
      throw RemoteException(_friendly(e));
    }

    final out = <RemoteEntry>[];
    for (final f in raw) {
      final name = f.name;
      if (name.isEmpty || name == '.' || name == '..') continue;
      if (name.startsWith('.')) continue; // 隐藏文件不显示（和 WebDAV 保持一致）

      final isDir = f.isDirectory();
      if (!isDir && !f.isExists) continue;

      final abs = f.path.replaceAll(RegExp(r'/+$'), '');
      _files[abs] = f;
      out.add(RemoteEntry(
        path: _rel(abs),
        isDir: isDir,
        size: f.size,
        modified: f.lastModified > 0
            ? DateTime.fromMillisecondsSinceEpoch(f.lastModified)
            : null,
      ));
    }

    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return naturalCompare(a.name, b.name);
    });
    return out;
  }

  // ------------------------------------------------------------- 播放地址

  @override
  MediaRef ref(String rel) => MediaRef(_bridge!.urlFor(_abs(rel)));

  // ------------------------------------------------------------- 自检

  @override
  Future<String> check() async {
    final entries = await list('');
    final dirs = entries.where((e) => e.isDir).length;
    final files = entries.length - dirs;

    // 挑一个文件走一遍本地中转，验证「播放链路」是通的。
    // 只列目录成功不代表能播 —— 权限可能只给了列目录。
    var playable = true;
    final probe = entries.where((e) => !e.isDir && e.size > 0).toList();
    if (probe.isNotEmpty) {
      playable = await _probe(probe.first.path);
    }

    final b = StringBuffer('连接正常：$dirs 个文件夹、$files 个文件');
    b.write(playable ? '；中转服务可用，能直接播放' : '；目录能看，但读取文件失败（可能是权限问题）');
    return b.toString();
  }

  Future<bool> _probe(String rel) async {
    final uri = Uri.parse(_bridge!.urlFor(_abs(rel)));
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
      final resp = await req.close();
      final ok = resp.statusCode == 206 || resp.statusCode == 200;
      await resp.drain<void>();
      return ok;
    } catch (e) {
      debugPrint('SMB 中转探测失败：$e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> dispose() async {
    await _bridge?.stop();
    _files.clear();
    try {
      await _conn?.close();
    } catch (_) {}
    _conn = null;
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('STATUS_LOGON_FAILURE') || s.contains('LOGON')) {
      return 'SMB 登录失败：用户名或密码不对';
    }
    if (s.contains('STATUS_ACCESS_DENIED') || s.contains('ACCESS_DENIED')) {
      return 'SMB 拒绝访问：这个账号没有该共享目录的读取权限';
    }
    if (s.contains('BAD_NETWORK_NAME') || s.contains('NOT_FOUND')) {
      return '找不到共享目录：检查「根目录」填的共享名是否正确（例如 /media）';
    }
    if (s.contains('SocketException') ||
        s.contains('Connection refused') ||
        s.contains('timed out') ||
        s.contains('Failed host lookup')) {
      return '连不上 SMB 服务器：检查 IP、端口 445 是否开放、电视和服务器是否同一网段';
    }
    if (s.contains('NOT_SUPPORTED') || s.contains('dialect')) {
      return '服务器只允许 SMB3：去服务器把最低协议改成 SMB2，或改用 WebDAV';
    }
    return 'SMB 出错：$s';
  }
}
