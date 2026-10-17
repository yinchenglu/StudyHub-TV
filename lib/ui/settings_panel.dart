import 'package:flutter/material.dart';

import '../core/fmt.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'list_panel.dart';

/// 「设置」面板。所有项都是"按一下切到下一个值"，
/// 不做滑块 / 输入框 —— 电视遥控上滑块太难对，输入框还要弹软键盘。
class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.app,
    required this.focusNode,
    required this.onRequestMenu,
  });

  final AppState app;
  final FocusNode focusNode;
  final VoidCallback onRequestMenu;

  @override
  Widget build(BuildContext context) {
    final s = app.store;
    const widths = [320, 480, 720];
    const densityLabels = ['大', '中', '小'];

    final items = <TvListItem>[
      TvListItem(
        title: '缩略图清晰度',
        subtitle: '越高越清楚，但更占内存和缓存空间',
        icon: Icons.high_quality_outlined,
        trailingText: '${s.thumbWidth}px',
        onTap: () {
          final i = widths.indexOf(s.thumbWidth);
          final next = widths[(i < 0 ? 1 : i + 1) % widths.length];
          app.updateSetting(() => s.setThumbWidth(next));
        },
      ),
      TvListItem(
        title: '卡片大小',
        subtitle: '一屏放多少张。字看不清楚就调大',
        icon: Icons.grid_view_rounded,
        trailingText: densityLabels[clampInt(s.density, 0, 2)],
        onTap: () {
          final next = (s.density + 1) % 3;
          app.updateSetting(() => s.setDensity(next));
        },
      ),
      TvListItem(
        title: '卡片显示文件名',
        subtitle: s.showNames ? '当前：显示' : '当前：不显示（画面更干净）',
        icon: Icons.label_outline,
        trailingText: s.showNames ? '开' : '关',
        onTap: () => app.updateSetting(() => s.setShowNames(!s.showNames)),
      ),
      TvListItem(
        title: '视频播完自动下一个',
        subtitle: '连续剧按顺序放，看完一集自动接下一集',
        icon: Icons.skip_next_outlined,
        trailingText: s.autoNext ? '开' : '关',
        onTap: () => app.updateSetting(() => s.setAutoNext(!s.autoNext)),
      ),
      TvListItem(
        title: '启动时默认打开',
        subtitle: '开机后直接落到哪个分区',
        icon: Icons.home_outlined,
        trailingText: s.startSection.label,
        onTap: () {
          const order = [Section.images, Section.videos, Section.audio];
          final i = order.indexOf(s.startSection);
          final next = order[(i < 0 ? 0 : i + 1) % order.length];
          app.updateSetting(() => s.setStartSection(next));
        },
      ),
      TvListItem(
        title: '图片自动播放',
        subtitle: '看照片时自动翻到下一张，当电子相框用',
        icon: Icons.slideshow_outlined,
        trailingText: s.slideshowSec == 0 ? '关' : '${s.slideshowSec} 秒',
        onTap: () {
          const steps = [0, 3, 5, 10, 30];
          final i = steps.indexOf(s.slideshowSec);
          final next = steps[(i < 0 ? 0 : i + 1) % steps.length];
          app.updateSetting(() => s.setSlideshowSec(next));
        },
      ),
    ];

    return TvListPanel(
      title: '设置',
      subtitle: '按 OK 切换取值，设置立即生效并记住。',
      items: items,
      focusNode: focusNode,
      onRequestMenu: onRequestMenu,
      footer: const Text(
        '缩略图缓存可以在「工具 → 清理缓存」里一次性删掉。',
        style: TextStyle(fontSize: 13, color: TvColors.textDim),
      ),
    );
  }
}
