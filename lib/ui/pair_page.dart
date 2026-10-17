import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../data/pair_server.dart';
import '../state/app_state.dart';
import 'tv_widgets.dart';

/// 「账户 → 手机扫码填写」页面。
///
/// 电视上打密码太痛苦（遥控器一格一格挪），所以这里开一个局域网小服务，
/// 把地址做成二维码：手机扫码 → 打开一个极简表单 → 提交后电视直接保存并连接。
///
/// 页面关掉 / 10 分钟超时，服务都会自动停 —— 它不是常驻服务。
class PairPage extends StatefulWidget {
  const PairPage({super.key, required this.app});

  final AppState app;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  PairServer? _server;
  bool _starting = true;
  String? _error;
  String? _savedName;
  bool? _savedConnected;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final s = PairServer(onSubmit: _onSubmit);
    final ok = await s.start();
    if (!mounted) {
      await s.stop();
      return;
    }
    setState(() {
      _starting = false;
      if (ok) {
        _server = s;
        _error = null;
      } else {
        _error = '没拿到这台电视的局域网 IP。\n'
            '请检查电视是不是已经连上 Wi-Fi / 网线，然后点「重试」。';
      }
    });
  }

  Future<void> _retry() async {
    await _server?.stop();
    setState(() {
      _server = null;
      _starting = true;
      _error = null;
    });
    await _start();
  }

  /// 手机提交后走这里：直接保存 + 连接，结果回显到手机页面上
  Future<String> _onSubmit(Account a) async {
    await widget.app.saveAccount(a);
    final connected = widget.app.connected;
    if (mounted) {
      setState(() {
        _savedName = a.name;
        _savedConnected = connected;
      });
    }
    return connected
        ? '已保存并连接成功：${a.name}'
        : '已保存「${a.name}」，但电视没连上。回电视上看具体原因（多半是地址或密码）。';
  }

  @override
  void dispose() {
    _server?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '返回',
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '手机扫码填写账号',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重建二维码'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: _starting
                    ? const CircularProgressIndicator()
                    : (_error != null ? _errorView() : _readyView()),
              ),
            ),
            const StatusBar(text: '二维码只在开着这个页面时有效，关掉就失效'),
          ],
        ),
      ),
    );
  }

  Widget _errorView() => Padding(
        padding: const EdgeInsets.all(30),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 58, color: TvColors.danger),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, height: 1.7),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('直接在电视上手动填写'),
              ),
            ],
          ),
        ),
      );

  Widget _readyView() {
    final s = _server!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(30, 10, 30, 30),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---- 二维码 ----
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: QrImageView(
                  data: s.url,
                  version: QrVersions.auto,
                  size: 300,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 34),
              // ---- 说明 ----
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '用手机扫左边的二维码',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '打开后是一个表单：填地址、账号、密码，点「保存到电视」。\n'
                      '电视会立刻保存并连接，不用在这边按任何键。',
                      style: TextStyle(
                          fontSize: 15, height: 1.8, color: TvColors.textDim),
                    ),
                    const SizedBox(height: 18),
                    _kv('手机要打开的地址', s.url),
                    const SizedBox(height: 10),
                    const Text(
                      '扫不出来？在手机浏览器里把上面这行地址手动敲进去也一样。',
                      style: TextStyle(fontSize: 13, color: TvColors.textDim),
                    ),
                    const SizedBox(height: 22),
                    _statusCard(),
                    const SizedBox(height: 18),
                    const Text(
                      '注意：手机和电视必须在同一个 Wi-Fi / 局域网里。\n'
                      '这个页面关掉之后，二维码立即失效。',
                      style: TextStyle(
                          fontSize: 13, height: 1.8, color: TvColors.textDim),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusCard() {
    if (_savedName == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: TvColors.card,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('等待手机提交…',
                style: TextStyle(fontSize: 15, color: TvColors.textDim)),
          ],
        ),
      );
    }
    final ok = _savedConnected == true;
    final c = ok ? TvColors.accent : TvColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: alpha(c, 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: alpha(c, 0.45)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 20, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ok ? '已收到「$_savedName」并连接成功' : '已保存「$_savedName」，但连接失败',
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: const TextStyle(fontSize: 12.5, color: TvColors.textDim)),
          const SizedBox(height: 4),
          SelectableText(
            v,
            style: const TextStyle(
              fontSize: 15,
              fontFamily: 'monospace',
              color: TvColors.accent,
            ),
          ),
        ],
      );
}
