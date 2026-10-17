import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fmt.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'image_viewer.dart';
import 'keys.dart';
import 'media_card.dart';
import 'player_page.dart';
import 'tv_widgets.dart';

/// 右侧内容区：按目录浏览图片 / 视频 / 音频。
///
/// 焦点也是"自己算 index"的模型（见 Sidebar 的注释）：
///   * 左右上下按格子数算，走到第一列再按左 → 焦点交回左侧菜单
///   * 上下会跨行，翻出屏幕时自动滚动
///   * 长按方向键连续移动靠 KeyRepeatEvent
class BrowserPanel extends StatefulWidget {
  const BrowserPanel({
    super.key,
    required this.app,
    required this.focusNode,
    required this.onRequestMenu,
    required this.onNeedAccount,
  });

  final AppState app;
  final FocusNode focusNode;
  final VoidCallback onRequestMenu;

  /// 没有账号时（理论上进不到这里，兜个底）跳到账户面板
  final VoidCallback onNeedAccount;

  @override
  State<BrowserPanel> createState() => _BrowserPanelState();
}

class _BrowserPanelState extends State<BrowserPanel> {
  int _index = 0;
  int _cols = 4;
  double _extent = 200;
  String _lastCwd = '\u0000';

  final ScrollController _scroll = ScrollController();

  AppState get app => widget.app;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 列表内容 = 当前目录的条目。
  /// v1.2 起**不再插入「返回上一级」这个假目录** ——
  /// 遥控器返回键就是回上级，多一格只能让人多按错一次。
  List<RemoteEntry> get _items => app.entries;

  // ------------------------------------------------------------- 按键

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final items = _items;

    if (isMenu(event)) {
      app.refresh();
      return KeyEventResult.handled;
    }

    if (isLeft(event)) {
      if (_index % _cols == 0) {
        widget.onRequestMenu();
      } else {
        _setIndex(_index - 1, items.length);
      }
      return KeyEventResult.handled;
    }

    if (isRight(event)) {
      _setIndex(_index + 1, items.length);
      return KeyEventResult.handled;
    }

    if (isUp(event)) {
      _setIndex(_index - _cols, items.length);
      return KeyEventResult.handled;
    }

    if (isDown(event)) {
      _setIndex(_index + _cols, items.length);
      return KeyEventResult.handled;
    }

    if (isSelect(event)) {
      if (items.isEmpty) {
        app.refresh();
      } else {
        _open(items[clampInt(_index, 0, items.length - 1)]);
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _setIndex(int v, int len) {
    if (len == 0) return;
    final next = clampInt(v, 0, len - 1);
    if (next == _index) return;
    setState(() => _index = next);
    _ensureVisible();
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    final row = _index ~/ _cols;
    final top = row * (_extent + _gap) ;
    final viewport = _scroll.position.viewportDimension;
    final bottom = top + _extent + _gap * 2;
    if (top < _scroll.offset) {
      _scroll.animateTo(top, duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    } else if (bottom > _scroll.offset + viewport) {
      _scroll.animateTo(bottom - viewport,
          duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    }
  }

  static const double _gap = 14;
  static const double _pad = 22;

  // ------------------------------------------------------------- 打开

  Future<void> _open(RemoteEntry e) async {
    if (e.isDir) {
      await app.enter(e.path);
      setState(() => _index = 0);
      return;
    }
    if (app.account == null) {
      widget.onNeedAccount();
      return;
    }

    final files = _items.where((x) => !x.isDir).toList();
    final i = files.indexWhere((x) => x.path == e.path);
    if (i < 0) return;

    if (e.kind == MediaKind.image) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ImageViewerPage(app: app, files: files, initial: i),
      ));
    } else {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerPage(app: app, files: files, initial: i),
      ));
    }
  }

  // ------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    // 目录切换后把光标拉回第一格（不然换目录会停在一个不存在的位置）
    if (_lastCwd != app.cwd) {
      _lastCwd = app.cwd;
      _index = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }

    final items = _items;
    if (items.isNotEmpty && _index >= items.length) _index = items.length - 1;

    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(items.length),
          Expanded(child: _body(items)),
          StatusBar(
            text: app.status.isNotEmpty
                ? app.status
                : (app.error != null ? app.error! : ''),
            warn: app.error != null,
          ),
        ],
      ),
    );
  }

  Widget _header(int count) {
    final crumbs = app.crumbs;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 10),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                for (var i = 0; i < crumbs.length; i++) ...[
                  if (i > 0)
                    const Icon(Icons.chevron_right,
                        size: 16, color: TvColors.textDim),
                  GestureDetector(
                    onTap: () => app.jumpToDepth(i),
                    child: Text(
                      crumbs[i],
                      style: TextStyle(
                        fontSize: 16,
                        color: i == crumbs.length - 1
                            ? TvColors.text
                            : TvColors.textDim,
                        fontWeight: i == crumbs.length - 1
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 分区根目录时把真实路径显示出来：用户一眼能看出
          // 「图片」到底对应服务器上的哪个文件夹（自动识别的结果）
          if (app.cwd == app.currentBase)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                app.baseDisplay,
                style: const TextStyle(fontSize: 12, color: TvColors.textDim),
              ),
            ),
          if (!app.loading)
            Text(
              '$count 项',
              style: const TextStyle(fontSize: 13, color: TvColors.textDim),
            ),
          const SizedBox(width: 14),
          _MiniButton(
            icon: Icons.refresh_rounded,
            label: '刷新',
            onTap: app.refresh,
          ),
        ],
      ),
    );
  }

  Widget _body(List<RemoteEntry> items) {
    if (app.loading && items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (app.error != null && items.isEmpty) {
      return ErrorBox(
        message: app.error!,
        onRetry: app.refresh,
      );
    }
    if (items.isEmpty) {
      return EmptyHint(app.section.emptyHint, icon: app.section.icon);
    }

    return LayoutBuilder(
      builder: (context, c) {
        // 密度：0 大 / 1 中 / 2 小
        final target = [340.0, 268.0, 206.0][clampInt(app.store.density, 0, 2)];
        _cols = clampInt(
          ((c.maxWidth - _pad * 2 + _gap) / (target + _gap)).floor(),
          1,
          12,
        );
        final cardW = (c.maxWidth - _pad * 2 - _gap * (_cols - 1)) / _cols;
        final nameH = app.store.showNames ? 50.0 : 0.0;
        final artRatio = app.section == Section.images ? 0.74 : 0.62;
        _extent = cardW * artRatio + nameH + 6;

        return GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(_pad, 4, _pad, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _cols,
            crossAxisSpacing: _gap,
            mainAxisSpacing: _gap,
            mainAxisExtent: _extent,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final e = items[i];
            MediaRef? ref;
            if (!e.isDir) {
              try {
                ref = app.ref(e.path);
              } catch (_) {
                ref = null;
              }
            }
            return MediaCard(
              entry: e,
              focused: widget.focusNode.hasFocus && i == _index,
              showName: app.store.showNames,
              thumbKey: app.thumbKey(e.path),
              thumbWidth: app.store.thumbWidth,
              ref: ref,
              onTap: () {
                setState(() => _index = i);
                widget.focusNode.requestFocus();
                _open(e);
              },
            );
          },
        );
      },
    );
  }
}

/// 右上角的小按钮（触摸用；遥控用菜单键代替）
class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: TvColors.card,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: TvColors.textDim),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(fontSize: 13, color: TvColors.textDim)),
          ],
        ),
      ),
    );
  }
}
