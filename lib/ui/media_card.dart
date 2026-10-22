import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/fmt.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/thumb_cache.dart';
import 'tv_widgets.dart';

/// 网格里的一张卡片：文件夹 / 图片 / 视频 / 音乐。
///
/// 缩略图策略：
///   * 图片 → 直接加载原图，但用 memCacheWidth 把解码尺寸压到卡片大小。
///     一张 4000×3000 的图按原尺寸解码要 48MB 内存，一屏 12 张直接 OOM。
///   * 视频 → 原生抽帧 + 磁盘缓存（ThumbCache），抽不出来就显示占位图标。
///   * 音乐 → 不做封面（V1 简化；mp3 内嵌封面要额外解析 ID3，收益不大）。
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.entry,
    required this.focused,
    required this.showName,
    required this.thumbKey,
    required this.thumbWidth,
    this.ref,
    required this.onTap,
  });

  final RemoteEntry entry;
  final bool focused;
  final bool showName;
  final String thumbKey;
  final int thumbWidth;
  final MediaRef? ref;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      // v1.8：图标和字号跟着卡片宽度缩。
      // 以前文件夹图标写死 58dp，卡片被压到 90dp 宽时图标比卡片还大，
      // 手机上看着就是"图标太大、一屏没几个"。
      final w = c.maxWidth;
      final iconSize = clampDouble(w * 0.34, 26, 58);
      final nameSize = clampDouble(w * 0.048 + 8, 10.5, 14.5);
      final subSize = clampDouble(w * 0.036 + 7, 8.5, 11);

      return FocusFrame(
        focused: focused,
        onTap: onTap,
        radius: 12,
        padding: const EdgeInsets.all(3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _art(w, iconSize),
                    if (entry.kind == MediaKind.video)
                      Positioned(
                        right: w < 120 ? 4 : 8,
                        bottom: w < 120 ? 4 : 8,
                        child: _Badge(
                          icon: Icons.play_arrow_rounded,
                          size: w < 120 ? 13 : 18,
                        ),
                      ),
                    if (entry.kind == MediaKind.audio)
                      Positioned(
                        right: w < 120 ? 4 : 8,
                        bottom: w < 120 ? 4 : 8,
                        child: _Badge(
                          icon: Icons.graphic_eq_rounded,
                          size: w < 120 ? 13 : 18,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (showName)
              Padding(
                padding: EdgeInsets.fromLTRB(w < 120 ? 5 : 8, 4, w < 120 ? 5 : 8, 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: nameSize,
                        fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
                        color: focused ? TvColors.text : const Color(0xFFD7DEE5),
                      ),
                    ),
                    if (!entry.isDir && entry.size > 0)
                      Text(
                        fmtBytes(entry.size),
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: subSize, color: TvColors.textDim),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }

  Widget _art(double w, double iconSize) {
    switch (entry.kind) {
      case MediaKind.folder:
        return Container(
          color: TvColors.card,
          child: Center(
            child: Icon(Icons.folder_rounded,
                size: iconSize, color: const Color(0xFFE8B84B)),
          ),
        );

      case MediaKind.image:
        final r = ref;
        if (r == null) {
          return _placeholder(Icons.image_not_supported_outlined, iconSize);
        }
        return CachedNetworkImage(
          imageUrl: r.url,
          httpHeaders: r.headers,
          fit: BoxFit.cover,
          memCacheWidth: thumbWidth,
          maxWidthDiskCache: thumbWidth * 2,
          // 不做淡入：低端盒子上 12 张卡片同时补间会掉帧，
          // 而且电视用户根本注意不到 150ms 的渐显，只感觉到"慢"
          fadeInDuration: Duration.zero,
          placeholder: (_, __) => Container(color: TvColors.card),
          errorWidget: (_, __, ___) =>
              _placeholder(Icons.broken_image_outlined, iconSize),
        );

      case MediaKind.video:
        final r = ref;
        if (r == null) return _placeholder(Icons.movie_outlined, iconSize);
        return FutureBuilder<File?>(
          future: ThumbCache.instance.get(
            key: thumbKey,
            url: r.url,
            headers: r.headers,
            width: thumbWidth,
          ),
          builder: (context, snap) {
            final f = snap.data;
            if (f != null) {
              return Image.file(
                f,
                fit: BoxFit.cover,
                cacheWidth: thumbWidth,
                errorBuilder: (_, __, ___) =>
                    _placeholder(Icons.movie_outlined, iconSize),
              );
            }
            if (snap.connectionState == ConnectionState.done) {
              return _placeholder(Icons.movie_outlined, iconSize);
            }
            final s = clampDouble(w * 0.2, 14, 22);
            return Container(
              color: TvColors.card,
              child: Center(
                child: SizedBox(
                  width: s,
                  height: s,
                  child: const CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
            );
          },
        );

      case MediaKind.audio:
        return Container(
          color: TvColors.card,
          child: Center(
            child: Icon(Icons.music_note_rounded,
                size: iconSize, color: TvColors.accent),
          ),
        );

      case MediaKind.other:
        return _placeholder(Icons.insert_drive_file_outlined, iconSize);
    }
  }

  Widget _placeholder(IconData icon, double size) => Container(
        color: TvColors.card,
        child: Center(
            child: Icon(icon, size: size * 0.8, color: TvColors.textDim)),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, this.size = 18});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: alpha(Colors.black, 0.55),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: size, color: Colors.white),
      );
}
