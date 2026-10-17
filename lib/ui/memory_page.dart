import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fmt.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../data/thumb_cache.dart';
import '../native/system_channel.dart';
import 'keys.dart';
import 'tv_widgets.dart';

/// 「工具 → 内存清理」。
///
/// 先把话说清楚（页面上也写着）：安卓从 4.4 起就不允许普通应用去杀别的
/// 应用、清别人的内存 —— 能清的只有**自己**的缓存。所以这一页做的是：
///   1. 把整机和本应用的内存占用摆出来，让用户知道到底是电视内存小，
///      还是这个 App 占得多；
///   2. 一键删掉本应用的缓存（缩略图 + 临时文件）并让虚拟机回收一轮，
///      电视上这通常能腾出几十到几百兆，界面也会明显不那么卡。
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  final FocusNode _node = FocusNode(debugLabel: 'memory');
  int _index = 0;
  int _actionCount = 3;

  MemInfo? _mem;
  bool _loading = true;
  bool _busy = false;
  String _status = '';
  (int, int) _thumbs = (0, 0); // 字节, 文件数

  @override
  void initState() {
    super.initState();
    _node.addListener(_redraw);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _node.requestFocus();
      _load();
    });
  }

  @override
  void dispose() {
    _node.removeListener(_redraw);
    _node.dispose();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final m = await SystemChannel.memory();
    final th = await ThumbCache.instance.usage();
    if (!mounted) return;
    setState(() {
      _mem = m;
      _thumbs = th;
      _loading = false;
      if (m == null) {
        _status = '读不到内存信息（当前不是安卓环境？）';
      }
    });
  }

  Future<void> _cleanAll() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在清理…';
    });
    final fromCache = await SystemChannel.clearCache();
    await ThumbCache.instance.clear();
    final thumbsBefore = _thumbs.$1;
    final m = await SystemChannel.memory();
    final th = await ThumbCache.instance.usage();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _mem = m;
      _thumbs = th;
      final freed = fromCache + thumbsBefore;
      _status = freed > 0
          ? '清理完成，释放约 ${_bytes(freed)}（缓存 ${_bytes(fromCache)}'
              '${thumbsBefore > 0 ? ' + 缩略图 ${_bytes(thumbsBefore)}' : ''}）'
          : '已经是干净的了，没有可清的缓存';
    });
  }

  Future<void> _cleanThumbs() async {
    if (_busy) return;
    final before = _thumbs;
    setState(() {
      _busy = true;
      _status = '正在清缩略图…';
    });
    await ThumbCache.instance.clear();
    final th = await ThumbCache.instance.usage();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _thumbs = th;
      _status = '已清缩略图：${before.$2} 个文件、${_bytes(before.$1)}';
    });
  }

  String _bytes(int b) => b <= 0 ? '0 B' : fmtBytes(b);

  // ------------------------------------------------------------- 按键

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    if (isUp(e)) {
      _move(_index - 1);
      return KeyEventResult.handled;
    }
    if (isDown(e)) {
      _move(_index + 1);
      return KeyEventResult.handled;
    }
    if (isLeft(e)) {
      if (mounted) Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (isSelect(e) || isRight(e)) {
      _run(_index);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _run(int i) {
    switch (i) {
      case 0:
        _cleanAll();
        break;
      case 1:
        _cleanThumbs();
        break;
      default:
        _load();
    }
  }

  void _move(int v) {
    final next = clampInt(v, 0, _actionCount - 1);
    if (next == _index) return;
    setState(() => _index = next);
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
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                            pagePad(context), 4, pagePad(context), 20),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 820),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _memoryCard(),
                                const SizedBox(height: 18),
                                _actions(),
                                const SizedBox(height: 16),
                                const Text(
                                  '安卓不允许一个应用去清别的应用的内存（能这么干的只有系统自己）。'
                                  '这里清的是 StudyHub TV 自己的缓存：视频封面、临时文件。\n'
                                  '删掉之后界面会更顺一点，下次进目录时会重新抽封面，不影响别的数据。',
                                  style: TextStyle(
                                      fontSize: 13,
                                      height: 1.6,
                                      color: TvColors.textDim),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
              StatusBar(
                text: _status.isNotEmpty ? _status : '↑↓ 选择 · OK 执行 · ← 返回工具',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return PageHeader(
      title: '内存清理',
      subtitle: _mem == null ? null : '整机已用 ${_bytes(_mem!.used)}',
      leading: IconButton(
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back),
        tooltip: '返回工具',
      ),
      actions: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }

  Widget _memoryCard() {
    final m = _mem;
    if (m == null) {
      return Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: TvColors.panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: TvColors.divider),
        ),
        child: const Text('这台设备读不到内存信息。',
            style: TextStyle(fontSize: 15, color: TvColors.textDim)),
      );
    }

    final ratio = m.usedRatio.clamp(0.0, 1.0).toDouble();
    final warn = ratio >= 0.85 || m.low;
    final color = warn ? TvColors.danger : TvColors.accent;

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
      decoration: BoxDecoration(
        color: TvColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TvColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('系统内存',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                '可用 ${_bytes(m.avail)} / 共 ${_bytes(m.total)}',
                style: TextStyle(fontSize: 14, color: color),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 10,
              backgroundColor: TvColors.divider,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '已用 ${_bytes(m.used)}（${(ratio * 100).toStringAsFixed(0)}%）'
            '${m.low ? ' · 系统已处于低内存状态' : ''}',
            style: const TextStyle(fontSize: 13, color: TvColors.textDim),
          ),
          const Divider(height: 26, color: TvColors.divider),
          Row(
            children: [
              Expanded(
                child: _kv('StudyHub TV 占用', _bytes(m.appUsed)),
              ),
              Expanded(
                child: _kv('缩略图缓存',
                    '${_bytes(_thumbs.$1)} · ${_thumbs.$2} 个'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k,
            style: const TextStyle(fontSize: 13, color: TvColors.textDim)),
        const SizedBox(height: 4),
        Text(v,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _actions() {
    final rows = <(IconData, String, String)>[
      (
        Icons.auto_fix_high_rounded,
        '一键清理',
        '清掉所有缓存并让系统回收一轮内存，电视卡的时候点这个'
      ),
      (
        Icons.image_not_supported_outlined,
        '只清缩略图',
        _thumbs.$2 > 0 ? '当前 ${_bytes(_thumbs.$1)}、${_thumbs.$2} 个文件' : '暂时没有缩略图缓存'
      ),
      (Icons.refresh_rounded, '刷新数据', '重新读一遍内存占用'),
    ];

    return Column(
      children: [
        for (var i = 0; i < rows.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: SizedBox(
              height: 66,
              child: TvRow(
                focused: _node.hasFocus && i == _index,
                title: rows[i].$2,
                subtitle: rows[i].$3,
                leading: Icon(rows[i].$1, size: 22, color: TvColors.textDim),
                trailing: i == 0
                    ? const Text('执行',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: TvColors.accent))
                    : null,
                onTap: () {
                  setState(() => _index = i);
                  _node.requestFocus();
                  _run(i);
                },
              ),
            ),
          ),
      ],
    );
  }
}
