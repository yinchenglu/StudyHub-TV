import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/fmt.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/thumb_cache.dart';
import '../native/system_channel.dart';
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
    // v1.7：加了「特小」一档。手机上原来最小档（96dp）一屏也只排 3 列，
    // 用户反馈还是太大 —— 特小按 74dp 排，360dp 宽能排 4 列、780dp 宽能排 9 列。
    const densityLabels = ['大', '中', '小', '特小'];

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
        trailingText: densityLabels[clampInt(s.density, 0, 3)],
        onTap: () {
          final next = (s.density + 1) % 4;
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
        title: '播放模式',
        subtitle: '播放器里也能改，两处是同一个设置',
        icon: s.playMode.icon,
        trailingText: s.playMode.label,
        onTap: () => app.updateSetting(() => s.setPlayMode(s.playMode.next)),
      ),
      // v1.6：这里原来有「跳过片头 / 片尾」一项，已经去掉。
      // 跳片头片尾改成了**按目录**记（在播放器里按菜单键设置），
      // 放在全局设置里既表达不了"哪个目录"，又和播放器里的入口重复。
      TvListItem(
        title: '视频硬解',
        subtitle: s.hwDecode
            ? '当前：交给电视自带的解码器（省电、1080p 更顺，个别机型会花屏就关掉）'
            : '当前：软件解码（兼容性最好，但高码率可能卡）',
        icon: Icons.memory_outlined,
        trailingText: s.hwDecode ? '开' : '关',
        onTap: () => app.updateSetting(() => s.setHwDecode(!s.hwDecode)),
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
      TvListItem(
        title: '下载保存位置',
        subtitle: s.downloadDir.isEmpty
            ? '当前：应用专属目录（不需要存储权限，最稳）'
            : '当前：${s.downloadDir}',
        icon: Icons.folder_special_outlined,
        trailingText: s.downloadDir.isEmpty ? '默认' : '自定义',
        onTap: () => _pickDownloadDir(context),
      ),
      TvListItem(
        title: '连接测试',
        subtitle: '检查账号、目录权限，以及视频能不能拖进度条',
        icon: Icons.network_check_rounded,
        onTap: () => _test(context),
      ),
      TvListItem(
        title: '清理缩略图缓存',
        subtitle: '视频封面缓存在电视本地，删掉不影响服务器',
        icon: Icons.cleaning_services_outlined,
        onTap: () => _cleanThumbs(context),
      ),
      TvListItem(
        title: '关于 / 诊断信息',
        subtitle: '版本号、当前协议、地址（发给别人求助时用）',
        icon: Icons.info_outline,
        onTap: () => _about(context),
      ),
    ];

    return TvListPanel(
      title: '设置',
      subtitle: '按 OK 切换取值，设置立即生效并记住。',
      items: items,
      focusNode: focusNode,
      onRequestMenu: onRequestMenu,
      footer: const Text(
        '内存和缓存的清理在「工具 → 内存清理」里。',
        style: TextStyle(fontSize: 13, color: TvColors.textDim),
      ),
    );
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _test(BuildContext context) async {
    final src = app.source;
    if (src == null) {
      _toast(context, '还没连上服务器，先去「账户」检查地址和密码');
      return;
    }
    _toast(context, '正在测试…');
    try {
      final msg = await src.check();
      if (!context.mounted) return;
      _toast(context, msg);
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '测试失败：$e');
    }
  }

  /// 选下载落盘目录。
  ///
  /// 为什么给"预设 + 自定义"而不是图形化目录选择器：
  ///   安卓 11 之后访问整块存储要用户单独去系统里开"所有文件访问"，
  ///   用 SAF 目录选择器（file_picker）又得引一个大依赖、还会返回
  ///   content:// 这种 dart:io 用不了的路径。预设值 + 手填路径最省事，
  ///   填错了下载时会自动退回应用专属目录，不会丢文件。
  Future<void> _pickDownloadDir(BuildContext context) async {
    final s = app.store;
    final st = await SystemChannel.storage();
    if (!context.mounted) return;
    final emu = (st?.emulated.isNotEmpty ?? false)
        ? st!.emulated
        : '/storage/emulated/0';

    final presets = <String, String>{
      '': '应用专属目录（默认，不需要任何权限）',
      '$emu/Download/StudyHubTV': '内部存储 / Download / StudyHubTV',
      '$emu/StudyHubTV': '内部存储 / StudyHubTV',
    };

    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: TvColors.panel,
        title: const Text('下载文件存到哪'),
        children: [
          for (final e in presets.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e.key),
              child: Row(
                children: [
                  Icon(
                    s.downloadDir == e.key
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: s.downloadDir == e.key
                        ? TvColors.accent
                        : TvColors.textDim,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.value,
                            style: const TextStyle(fontSize: 14.5)),
                        if (e.key.isNotEmpty)
                          Text(e.key,
                              style: const TextStyle(
                                  fontSize: 11.5, color: TvColors.textDim)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 18, color: TvColors.divider),
          SimpleDialogOption(
            onPressed: () async {
              Navigator.pop(ctx);
              await _inputCustomDir(context, emu);
            },
            child: const Row(
              children: [
                Icon(Icons.edit_outlined, size: 18, color: TvColors.textDim),
                SizedBox(width: 10),
                Text('手动输入路径…', style: TextStyle(fontSize: 14.5)),
              ],
            ),
          ),
          if (st != null && !st.allFiles)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                '提示：安卓 11 以上要写系统目录，得先去「工具 → 文件管理」里'
                '点一下"开启所有文件访问"。没开也能下载，会自动存到应用专属目录。',
                style: TextStyle(
                    fontSize: 12, height: 1.5, color: TvColors.textDim),
              ),
            ),
        ],
      ),
    );

    if (picked == null) return;
    await app.updateSetting(() => s.setDownloadDir(picked));
    if (!context.mounted) return;
    _toast(context, picked.isEmpty ? '下载目录已设为应用专属目录' : '下载目录已设为 $picked');
  }

  Future<void> _inputCustomDir(BuildContext context, String emu) async {
    final ctrl = TextEditingController(text: app.store.downloadDir);
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: const Text('下载目录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '$emu/Download/StudyHubTV',
                helperText: '留空 = 应用专属目录',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (path == null) return;
    await app.updateSetting(() => app.store.setDownloadDir(path));
    if (!context.mounted) return;
    _toast(context, path.isEmpty ? '已恢复默认目录' : '已保存：$path');
  }

  Future<void> _cleanThumbs(BuildContext context) async {    final before = await ThumbCache.instance.usage();
    await app.clearThumbs();
    if (!context.mounted) return;
    _toast(context,
        '已清理缩略图缓存：${before.$2} 个文件、${fmtBytes(before.$1)}');
  }

  void _about(BuildContext context) {
    final a = app.account;
    final lines = [
      '版本：v$kAppVersion',
      '当前账号：${a?.name ?? '无'}',
      '协议：${a?.proto.label ?? '-'}',
      '地址：${a?.summary ?? '-'}',
      '状态：${app.connected ? '已连接' : '未连接'}',
      '',
      kRepoUrl,
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvColors.panel,
        title: const Text('关于 StudyHub TV'),
        content: SelectableText(
          lines.join('\n'),
          style: const TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
