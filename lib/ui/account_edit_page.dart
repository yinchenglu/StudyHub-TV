import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../data/remote/remote_source.dart';
import '../state/app_state.dart';

/// 新增 / 编辑账号。
///
/// 电视上填表单是最烦的一步，所以这里做了三件事：
///   1. 默认值尽量填好（端口 445、根目录留空、名称自动起）
///   2. 提供「测试并保存」—— 一次点击就把"地址对不对、密码通不通"验完，
///      不用存下来再回列表试
///   3. 每个输入框回车自动跳下一个，不用来回找焦点
class AccountEditPage extends StatefulWidget {
  const AccountEditPage({super.key, required this.app, this.account});

  final AppState app;
  final Account? account;

  @override
  State<AccountEditPage> createState() => _AccountEditPageState();
}

class _AccountEditPageState extends State<AccountEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _addr;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _pwd;
  late final TextEditingController _root;
  late final TextEditingController _domain;

  late Proto _proto;

  final _nName = FocusNode();
  final _nAddr = FocusNode();
  final _nPort = FocusNode();
  final _nUser = FocusNode();
  final _nPwd = FocusNode();
  final _nRoot = FocusNode();
  final _nDomain = FocusNode();

  bool _busy = false;
  bool _obscure = true;
  String? _error;
  String? _ok;

  bool get isNew => widget.account == null;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _proto = a?.proto ?? Proto.webdav;
    _name = TextEditingController(text: a?.name ?? '');
    _addr = TextEditingController(text: a?.addr ?? '');
    _port = TextEditingController(text: '${a?.port ?? 445}');
    _user = TextEditingController(text: a?.user ?? '');
    _pwd = TextEditingController(text: a?.password ?? '');
    _root = TextEditingController(text: a?.root ?? '');
    _domain = TextEditingController(text: a?.domain ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _addr, _port, _user, _pwd, _root, _domain]) {
      c.dispose();
    }
    for (final n in [_nName, _nAddr, _nPort, _nUser, _nPwd, _nRoot, _nDomain]) {
      n.dispose();
    }
    super.dispose();
  }

  Account _build() => Account(
        id: widget.account?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: _name.text.trim().isEmpty ? '我的服务器' : _name.text.trim(),
        proto: _proto,
        addr: _addr.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 445,
        user: _user.text.trim(),
        password: _pwd.text,
        root: _root.text.trim(),
        domain: _domain.text.trim(),
      );

  // ------------------------------------------------------------- 动作

  Future<void> _testAndSave() async {
    final a = _build();
    if (a.addr.isEmpty) {
      setState(() => _error = '地址不能为空');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });

    RemoteSource? tmp;
    try {
      tmp = await RemoteSource.open(a);
      final msg = await tmp.check();
      await tmp.dispose();
      tmp = null;
      if (!mounted) return;
      setState(() {
        _ok = msg;
        _busy = false;
      });
      await widget.app.saveAccount(a);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存并连接：$msg'), duration: const Duration(seconds: 3)),
      );
    } catch (e) {
      if (tmp != null) {
        try {
          await tmp.dispose();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _saveOnly() async {
    final a = _build();
    if (a.addr.isEmpty) {
      setState(() => _error = '地址不能为空');
      return;
    }
    await widget.app.saveAccount(a);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final isSmb = _proto == Proto.smb;
    return Scaffold(
      backgroundColor: TvColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 18, 30, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '返回',
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isNew ? '添加账号' : '编辑账号',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 16),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(30, 10, 30, 30),
                    children: [
                      _protoSwitch(),
                      const SizedBox(height: 18),
                      _field(
                        controller: _name,
                        node: _nName,
                        label: '名称（随便起，会显示在左边菜单里）',
                        hint: '客厅 NAS',
                        next: _nAddr,
                      ),
                      _field(
                        controller: _addr,
                        node: _nAddr,
                        label: isSmb ? '服务器地址（IP 或主机名）' : 'WebDAV 地址（要带 http:// 和端口）',
                        hint: _proto.addrHint,
                        next: _nUser,
                        keyboard: TextInputType.url,
                      ),
                      if (isSmb)
                        _field(
                          controller: _port,
                          node: _nPort,
                          label: '端口（默认 445，一般不用改）',
                          hint: '445',
                          next: _nUser,
                          keyboard: TextInputType.number,
                        ),
                      _field(
                        controller: _user,
                        node: _nUser,
                        label: '用户名',
                        hint: isSmb ? 'SMB 账号（可留空 = 匿名）' : 'WebDAV 账号',
                        next: _nPwd,
                      ),
                      _field(
                        controller: _pwd,
                        node: _nPwd,
                        label: '密码',
                        hint: '',
                        next: _nRoot,
                        obscure: _obscure,
                        suffix: IconButton(
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(
                            _obscure ? Icons.visibility_off : Icons.visibility,
                            size: 20,
                          ),
                        ),
                      ),
                      _field(
                        controller: _root,
                        node: _nRoot,
                        label: isSmb ? '共享目录（共享名 + 子目录）' : '子目录（可留空）',
                        hint: _proto.rootHint,
                        next: isSmb ? _nDomain : null,
                        onDone: _testAndSave,
                      ),
                      if (isSmb)
                        _field(
                          controller: _domain,
                          node: _nDomain,
                          label: '域（Windows 域账号才要，家用 NAS 留空）',
                          hint: '',
                          onDone: _testAndSave,
                        ),

                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        _banner(_error!, true),
                      ],
                      if (_ok != null) ...[
                        const SizedBox(height: 14),
                        _banner(_ok!, false),
                      ],

                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy ? null : _testAndSave,
                              icon: const Icon(Icons.check_circle_outline),
                              label: const Text('测试并保存'),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 18),
                                textStyle: const TextStyle(fontSize: 17),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          OutlinedButton(
                            onPressed: _busy ? null : _saveOnly,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 18, horizontal: 22),
                              textStyle: const TextStyle(fontSize: 16),
                            ),
                            child: const Text('仅保存'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        '填不准怎么办：\n'
                        '· WebDAV 先在电脑浏览器里试：地址栏能打开、弹框要账号密码就是对的\n'
                        '· SMB 的共享目录要先在电脑上能看到，例如 \\\\192.168.1.10\\media\n'
                        '   那么在「共享目录」里就填 /media\n'
                        '· 电视和服务器必须在同一个路由器下（或能互相 ping 通）',
                        style: TextStyle(
                            fontSize: 13, height: 1.9, color: TvColors.textDim),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _protoSwitch() {
    Widget seg(Proto p) {
      final active = _proto == p;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _proto = p),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: active ? alpha(TvColors.accent, 0.18) : TvColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active ? TvColors.accent : TvColors.divider,
                width: 2,
              ),
            ),
            child: Center(
              child: Text(
                p == Proto.webdav ? 'WebDAV' : 'SMB / 共享文件夹',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: active ? TvColors.accent : TvColors.textDim,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        seg(Proto.webdav),
        const SizedBox(width: 12),
        seg(Proto.smb),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required FocusNode node,
    required String label,
    required String hint,
    FocusNode? next,
    TextInputType? keyboard,
    bool obscure = false,
    Widget? suffix,
    VoidCallback? onDone,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        focusNode: node,
        obscureText: obscure,
        keyboardType: keyboard,
        textInputAction: onDone != null ? TextInputAction.done : TextInputAction.next,
        onSubmitted: (_) {
          if (onDone != null) {
            onDone();
          } else if (next != null) {
            FocusScope.of(context).requestFocus(next);
          }
        },
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon: suffix,
        ),
      ),
    );
  }

  Widget _banner(String text, bool isError) {
    final c = isError ? TvColors.danger : TvColors.accent;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: alpha(c, 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: alpha(c, 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isError ? Icons.error_outline : Icons.check_circle_outline,
              size: 20, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: 14, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
