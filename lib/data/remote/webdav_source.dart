import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../../core/fmt.dart';
import '../models.dart';
import 'remote_source.dart';

/// WebDAV 实现。
///
/// 为什么手写而不用现成库：需要自己控制三件现成库做不好的事 ——
///   1. 中文路径逐段百分号编码（整条 URL 一起 encode 会把 / 也编掉）
///   2. 服务器不支持 Depth:1 时自动降级成 Depth:infinity 再自己筛一层
///      （chfs、部分老版群晖会这样）
///   3. 把 HTTP 状态码翻译成人话（401 是密码错、403 是没权限……）
///
/// 代码是从 StudyHub 的 WebDAV 客户端裁出来的：只保留电视端要用的
/// 「列目录 + 拿地址 + 自检」，写入/上传/删除那些用不上，全部去掉。
class WebDavSource implements RemoteSource {
  @override
  final Account account;

  late final Dio _dio;

  /// 服务器不支持 Depth:1 时置 false（见 list 里的降级逻辑）
  bool _deepListOk = true;

  WebDavSource(this.account) {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
      maxRedirects: 5,
      // 不让 dio 因为 4xx 抛异常：我们要自己读状态码给人话提示
      validateStatus: (s) => s != null && s < 500,
      headers: {'Authorization': auth, 'User-Agent': 'StudyHubTV/1.0'},
    ));
  }

  // ----------------------------------------------------------- 地址拼接

  String get auth =>
      'Basic ${base64Encode(utf8.encode('${account.user}:${account.password}'))}';

  Map<String, String> get headers => {'Authorization': auth};

  /// 规范化后的入口地址：补协议、去尾部斜杠
  String get _base {
    var b = account.addr.trim();
    if (b.isEmpty) b = 'http://127.0.0.1';
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'http://$b';
    }
    return b.replaceAll(RegExp(r'/+$'), '');
  }

  /// 入口地址里的路径部分，例如 https://nas/dav → /dav
  String get _basePath => Uri.tryParse(_base)?.path.replaceAll(RegExp(r'/+$'), '') ?? '';

  List<String> get _rootSegs =>
      account.root.split('/').where((e) => e.trim().isNotEmpty).toList();

  /// 相对路径 → 服务器上的绝对路径（未编码）
  String _absolute(String rel) {
    final segs = <String>[
      ..._rootSegs,
      ...rel.split('/').where((e) => e.isNotEmpty),
    ];
    return '/${segs.join('/')}';
  }

  /// 逐段编码：中文、空格、# 都不会出错
  static String _encodePath(String abs) {
    final segs = abs.split('/').where((e) => e.isNotEmpty).map(Uri.encodeComponent);
    return '/${segs.join('/')}';
  }

  /// 拼出可访问的完整地址
  String _url(String abs, {bool asDir = false}) {
    final p = _encodePath(abs);
    final tail = asDir ? (p.endsWith('/') ? p : '$p/') : p;
    return '$_base$tail';
  }

  // ----------------------------------------------------------- 列目录

  @override
  Future<List<RemoteEntry>> list(String rel) async {
    var entries = await _propfind(rel, depth: 1);
    // 只回来一条（或者干脆是空的）→ 多半是服务器不支持 Depth:1，
    // 换成 infinity 全递归回来，再自己筛掉孙子辈的
    if (entries.length <= 1) {
      try {
        final deep = await _propfind(rel, depth: -1);
        if (deep.length > entries.length) {
          _deepListOk = false;
          entries = _onlyChildren(rel, deep);
        }
      } catch (_) {
        _deepListOk = false;
      }
    }
    return entries;
  }

  List<RemoteEntry> _onlyChildren(String rel, List<RemoteEntry> all) {
    final base = rel.replaceAll(RegExp(r'^/+|/+$'), '');
    final prefix = base.isEmpty ? '' : '$base/';
    return all.where((e) {
      if (!e.path.startsWith(prefix)) return false;
      final rest = e.path.substring(prefix.length);
      return rest.isNotEmpty && !rest.contains('/');
    }).toList();
  }

  Future<List<RemoteEntry>> _propfind(String rel, {int depth = 1}) async {
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:"><d:prop>'
        '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>'
        '</d:prop></d:propfind>';
    try {
      final resp = await _dio.request<String>(
        _url(_absolute(rel), asDir: true),
        data: body,
        options: Options(
          method: 'PROPFIND',
          headers: {
            'Depth': depth < 0 ? 'infinity' : '$depth',
            'Content-Type': 'application/xml; charset=utf-8',
          },
          responseType: ResponseType.plain,
        ),
      );
      final code = resp.statusCode ?? 0;
      if (code == 207 || code == 200) {
        return _parse(resp.data ?? '', rel);
      }
      if (code == 401) throw RemoteException('账号或密码不对（HTTP 401）');
      if (code == 403) throw RemoteException('这个账号没有访问该目录的权限（HTTP 403）');
      if (code == 404) throw RemoteException('路径不存在（HTTP 404）：${account.root}$rel');
      if (code == 405) {
        throw RemoteException('服务器没开 WebDAV，或不允许列目录（HTTP 405）');
      }
      throw RemoteException('列目录失败：HTTP $code');
    } on DioException catch (e) {
      throw RemoteException(_friendly(e));
    }
  }

  List<RemoteEntry> _parse(String xmlText, String requestRel) {
    final out = <RemoteEntry>[];
    if (xmlText.trim().isEmpty) return out;
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlText);
    } catch (_) {
      throw RemoteException('服务器返回的不是标准 WebDAV 数据，可能没开 WebDAV 服务');
    }
    final self = requestRel.replaceAll(RegExp(r'^/+|/+$'), '');

    for (final resp in doc.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'response')) {
      String? href;
      for (final h in resp.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'href')) {
        href = h.innerText.trim();
        break;
      }
      if (href == null || href.isEmpty) continue;

      final rel = _hrefToRel(href);
      if (rel == null) continue;
      if (rel == self) continue; // 目录自己

      final name = rel.contains('/') ? rel.substring(rel.lastIndexOf('/') + 1) : rel;
      if (name.isEmpty || name.startsWith('.')) continue; // 跳过 .DS_Store 之类

      final isDir = resp.descendants
          .any((n) => n is XmlElement && n.name.local == 'collection');
      final size = int.tryParse(_inner(resp, 'getcontentlength') ?? '') ?? 0;
      final mod = _parseDate(_inner(resp, 'getlastmodified'));

      out.add(RemoteEntry(path: rel, isDir: isDir, size: size, modified: mod));
    }

    // 目录在前，同类按自然序（第2集排在第10集前面）
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return naturalCompare(a.name, b.name);
    });
    return out;
  }

  String? _inner(XmlElement resp, String localName) {
    for (final e in resp.descendants.whereType<XmlElement>()) {
      if (e.name.local == localName) return e.innerText;
    }
    return null;
  }

  DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return HttpDate.parse(s).toLocal();
    } catch (_) {
      return DateTime.tryParse(s);
    }
  }

  /// 服务器返回的 href → 相对账号根目录的路径。不属于本根目录的返回 null。
  String? _hrefToRel(String href) {
    String path;
    if (href.startsWith('http://') || href.startsWith('https://')) {
      path = Uri.parse(href).path;
    } else {
      path = href;
    }
    var decoded = path;
    try {
      decoded = Uri.decodeComponent(path);
    } catch (_) {}

    final bp = _basePath;
    if (bp.isNotEmpty && decoded.startsWith(bp)) {
      decoded = decoded.substring(bp.length);
    }

    final segs = decoded.split('/').where((e) => e.isNotEmpty).toList();
    final root = _rootSegs;
    if (root.isNotEmpty) {
      if (segs.length < root.length) return null;
      for (var i = 0; i < root.length; i++) {
        if (segs[i] != root[i]) return null;
      }
      segs.removeRange(0, root.length);
    }
    return segs.join('/');
  }

  // ----------------------------------------------------------- 播放地址

  @override
  MediaRef ref(String rel) => MediaRef(_url(_absolute(rel)), headers);

  // ----------------------------------------------------------- 自检

  @override
  Future<String> check() async {
    final root = await list('');
    final dirs = root.where((e) => e.isDir).length;
    final files = root.length - dirs;

    // 顺手试试服务器支不支持 Range —— 不支持的话视频拖不了进度条，
    // 得提前告诉用户，不然他会以为播放器坏了
    var range = false;
    RemoteEntry? probe;
    for (final e in root) {
      if (!e.isDir && e.size > 1024) {
        probe = e;
        break;
      }
    }
    if (probe != null) range = await _testRange(probe.path);

    final b = StringBuffer('连接正常：$dirs 个文件夹、$files 个文件');
    b.write(range
        ? '；支持拖进度条'
        : '；服务器不支持 Range（视频不能拖进度条，能正常播放）');
    return b.toString();
  }

  Future<bool> _testRange(String rel) async {
    try {
      final resp = await _dio.get<List<int>>(
        _url(_absolute(rel), asDir: false),
        options: Options(
          headers: {'Range': 'bytes=0-1'},
          responseType: ResponseType.bytes,
          validateStatus: (s) => true,
        ),
      );
      return resp.statusCode == 206;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _dio.close(force: true);
  }

  String _friendly(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时：服务器没响应，检查地址、端口，以及电视和服务器是否在同一个网络';
      case DioExceptionType.connectionError:
        return '连不上服务器：${e.message ?? ''}\n（检查地址端口的填写，是否 http/https 写反）';
      case DioExceptionType.badCertificate:
        return 'HTTPS 证书不被信任：自建服务器常见，可改用 http 试试';
      default:
        return '网络错误：${e.message ?? e.type.toString()}';
    }
  }

  /// 给「断线重连」用的空实现标记（预留给 V2 的自动重试）
  bool get isClosed => false;
}
