import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import 'models.dart';

/// 扫码填写账号用的本地网页服务。
///
/// 为什么要在电视上开一个 HTTP 服务：
///   电视遥控器打字是灾难（拼音一格一格挪），所以让手机来填。
///   电视上显示二维码 → 手机扫码打开一个极简表单 → 提交后电视直接收到。
///
/// 安全上的三条：
///   1. URL 里带一次性随机 token（`?k=xxxxxx`），局域网里别的设备扫不到就进不来；
///   2. 只接受 `/` 和 `/save` 两个路径，其它一律 404；
///   3. 页面关掉 / 提交完成 / 超时（10 分钟）后服务自动关闭。
/// 注意：这是明文 http，同 Wi-Fi 下有心的邻居理论上能嗅探 ——
/// 所以它只在"添加账号"这一分钟内开着，不是常驻服务。
class PairServer {
  PairServer({required this.onSubmit});

  /// 收到表单内容后的处理（保存 + 连接），返回值会回显到手机上
  final Future<String> Function(Account account) onSubmit;

  HttpServer? _server;
  int _port = 0;
  String _token = '';
  String _ip = '';
  Timer? _timeout;

  bool get running => _server != null;
  int get port => _port;
  String get ip => _ip;
  String get token => _token;

  /// 手机上要打开的地址
  String get url => 'http://$_ip:$_port/?k=$_token';

  /// 启动服务，返回是否成功（没有局域网 IP 时会失败）
  Future<bool> start() async {
    if (_server != null) return true;

    _ip = await _lanIpv4() ?? '';
    if (_ip.isEmpty) return false;

    _token = _randomToken();
    try {
      final s = await HttpServer.bind(InternetAddress.anyIPv4, kPairPort);
      s.autoCompress = false;
      _server = s;
      _port = s.port;
      s.listen(
        (req) => _handle(req),
        onError: (Object e) => debugPrint('扫码服务异常：$e'),
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('扫码服务启动失败：$e');
      _server = null;
      return false;
    }

    // 页面忘了关也不会一直暴露：10 分钟后自动停
    _timeout?.cancel();
    _timeout = Timer(const Duration(minutes: 10), stop);
    debugPrint('扫码服务已启动：$url');
    return true;
  }

  Future<void> stop() async {
    _timeout?.cancel();
    _timeout = null;
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  static String _randomToken() {
    const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// 找本机的局域网 IPv4（跳过 loopback / 虚拟网卡）
  static Future<String?> _lanIpv4() async {
    try {
      final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final all = <String>[];
      for (final ni in list) {
        for (final a in ni.addresses) {
          final ip = a.address;
          if (ip.startsWith('127.')) continue;
          if (ip.startsWith('169.254.')) continue;
          all.add(ip);
        }
      }
      if (all.isEmpty) return null;
      // 优先常见的家用网段，避免选到 docker / VPN 的虚拟网卡
      for (final ip in all) {
        if (ip.startsWith('192.168.')) return ip;
      }
      for (final ip in all) {
        if (ip.startsWith('10.')) return ip;
      }
      for (final ip in all) {
        if (ip.startsWith('172.')) {
          final second = int.tryParse(ip.split('.')[1]) ?? 0;
          if (second >= 16 && second <= 31) return ip;
        }
      }
      return all.first;
    } catch (e) {
      debugPrint('取局域网 IP 失败：$e');
      return null;
    }
  }

  // ------------------------------------------------------------- 请求处理

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final q = req.uri.queryParameters;
      if (q['k'] != _token) {
        res.statusCode = HttpStatus.forbidden;
        res.headers.contentType = ContentType.html;
        res.write(_forbiddenPage());
        await res.close();
        return;
      }

      if (req.method == 'GET' && (req.uri.path == '/' || req.uri.path == '/index.html')) {
        res.headers.contentType = ContentType.html;
        res.write(_formPage());
        await res.close();
        return;
      }

      if (req.method == 'POST' && req.uri.path == '/save') {
        final body = await utf8.decoder.bind(req).join();
        final f = Uri.splitQueryString(body);
        final acc = _toAccount(f);
        if (acc.addr.trim().isEmpty) {
          res.statusCode = HttpStatus.badRequest;
          res.headers.contentType = ContentType.html;
          res.write(_resultPage(ok: false, msg: '服务器地址不能为空，请回到上一页重新填写'));
          await res.close();
          return;
        }
        try {
          final msg = await onSubmit(acc);
          res.headers.contentType = ContentType.html;
          res.write(_resultPage(ok: true, msg: msg));
        } catch (e) {
          res.statusCode = HttpStatus.ok;
          res.headers.contentType = ContentType.html;
          res.write(_resultPage(ok: false, msg: '电视保存失败：$e'));
        }
        await res.close();
        return;
      }

      res.statusCode = HttpStatus.notFound;
      await res.close();
    } catch (e) {
      debugPrint('扫码请求失败：$e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  Account _toAccount(Map<String, String> f) {
    String v(String k) => (f[k] ?? '').trim();
    final proto = v('proto') == 'smb' ? Proto.smb : Proto.webdav;
    var addr = v('addr');
    if (proto == Proto.webdav &&
        addr.isNotEmpty &&
        !addr.startsWith('http://') &&
        !addr.startsWith('https://')) {
      addr = 'http://$addr';
    }
    return Account(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: v('name').isEmpty ? '我的服务器' : v('name'),
      proto: proto,
      addr: addr,
      port: int.tryParse(v('port')) ?? 445,
      user: v('user'),
      password: f['pwd'] ?? '',
      root: v('root'),
      domain: v('domain'),
    );
  }

  // ------------------------------------------------------------- 页面

  static const _css = '''
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 22px 18px 40px;
      font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
      background: #0c1218; color: #e8eef4;
    }
    h1 { font-size: 21px; margin: 0 0 6px; }
    p  { color: #8fa3b3; font-size: 13.5px; line-height: 1.7; margin: 0 0 16px; }
    label { display: block; font-size: 13px; color: #9fb3c3; margin: 14px 0 6px; }
    input, select {
      width: 100%; padding: 13px 14px; font-size: 16px;
      background: #151f28; color: #e8eef4;
      border: 1px solid #26333d; border-radius: 10px; outline: none;
    }
    input:focus, select:focus { border-color: #35d0e0; }
    .row { display: flex; gap: 10px; }
    .row > div { flex: 1; }
    button {
      width: 100%; margin-top: 26px; padding: 16px;
      font-size: 17px; font-weight: 700; color: #06222b;
      background: #35d0e0; border: 0; border-radius: 12px;
    }
    .hint { font-size: 12.5px; color: #6f8494; line-height: 1.7; margin-top: 18px; }
    .big { font-size: 46px; margin: 8px 0 4px; }
    .card { background: #131c24; border: 1px solid #22303a; border-radius: 14px; padding: 18px; }
    code { background: #1b262f; padding: 1px 5px; border-radius: 4px; }
  ''';

  String _head(String title) => '''
<!DOCTYPE html><html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>$title</title><style>$_css</style></head><body>
''';

  String _formPage() => '''
${_head('填写 StudyHub TV 账号')}
<h1>填写你的 NAS 账号</h1>
<p>填完点最下面的按钮，电视那边会自动保存并连接。手机可以慢慢打字，电视不用动。</p>
<form method="post" action="/save?k=$_token">
  <label>协议</label>
  <select name="proto" id="proto" onchange="toggleProto()">
    <option value="webdav">WebDAV（群晖 / 威联通 / Alist 等）</option>
    <option value="smb">SMB 共享文件夹（Windows / NAS）</option>
  </select>

  <label>名称（随便起，显示在电视菜单里）</label>
  <input name="name" placeholder="客厅 NAS" autocomplete="off">

  <label id="addrLabel">WebDAV 地址（带 http:// 和端口）</label>
  <input name="addr" id="addr" placeholder="http://192.168.1.10:5005" autocapitalize="off" autocorrect="off" spellcheck="false">

  <div class="row" id="portRow" style="display:none">
    <div>
      <label>SMB 端口</label>
      <input name="port" value="445" inputmode="numeric">
    </div>
    <div>
      <label>域（一般留空）</label>
      <input name="domain" placeholder="WORKGROUP" autocapitalize="off">
    </div>
  </div>

  <label>用户名</label>
  <input name="user" autocomplete="username" autocapitalize="off" autocorrect="off">

  <label>密码</label>
  <input name="pwd" type="password" autocomplete="current-password">

  <label id="rootLabel">子目录（一般留空）</label>
  <input name="root" id="root" placeholder="/dav" autocapitalize="off" autocorrect="off" spellcheck="false">

  <button type="submit">保存到电视</button>
</form>
<div class="hint">
  · 电视会在 <code>StudyHub-TV/image</code>、<code>video</code>、<code>audio</code> 里找内容，这三个文件夹不用在这里填<br>
  · WebDAV 地址先在电脑浏览器里试一下：能打开、弹框要账号密码就是对的<br>
  · SMB 的「子目录」填共享名，例如共享是 <code>\\\\192.168.1.10\\media</code> 就填 <code>/media</code>
</div>
<script>
function toggleProto() {
  var smb = document.getElementById('proto').value === 'smb';
  document.getElementById('portRow').style.display = smb ? 'flex' : 'none';
  document.getElementById('addr').placeholder = smb ? '192.168.1.10' : 'http://192.168.1.10:5005';
  document.getElementById('addrLabel').textContent = smb ? '服务器地址（IP 或主机名）' : 'WebDAV 地址（带 http:// 和端口）';
  document.getElementById('rootLabel').textContent = smb ? '共享目录（共享名 + 子目录）' : '子目录（一般留空）';
  document.getElementById('root').placeholder = smb ? '/media' : '/dav';
}
</script>
</body></html>
''';

  String _resultPage({required bool ok, required String msg}) => '''
${_head(ok ? '已发送到电视' : '没成功')}
<div class="card">
  <div class="big">${ok ? '✅' : '⚠️'}</div>
  <h1>${ok ? '已经发送到电视' : '电视没有接受'}</h1>
  <p>${_escape(msg)}</p>
</div>
<div class="hint">${ok ? '现在可以关掉这个页面了。电视上应该已经显示「已连接」。' : '回到上一页改一下再提交，或者直接在电视上手动填写。'}</div>
<p style="margin-top:22px"><a href="/?k=$_token" style="color:#35d0e0">← 返回修改</a></p>
</body></html>
''';

  String _forbiddenPage() => '''
${_head('链接已失效')}
<h1>链接已失效</h1>
<p>这个二维码是上一次生成的，已经关了。<br>回电视上重新点「手机扫码填写」再扫一次。</p>
</body></html>
''';

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
