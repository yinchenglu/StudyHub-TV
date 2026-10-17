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
                  _art(),
                  if (entry.kind == MediaKind.video)
                    const Positioned(
                      right: 8,
                      bottom: 8,
                      child: _Badge(icon: Icons.play_arrow_rounded),
                    ),
                  if (entry.kind == MediaKind.audio)
                    const Positioned(
                      right: 8,
                      bottom: 8,
                      child: _Badge(icon: Icons.graphic_eq_rounded),
                    ),
                ],
              ),
            ),
          ),
          if (showName)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
                      color: focused ? TvColors.text : const Color(0xFFD7DEE5),
                    ),
                  ),
                  if (!entry.isDir && entry.size > 0)
                    Text(
                      fmtBytes(entry.size),
                      maxLines: 1,
                      style: const TextStyle(fontSize: 11, color: TvColors.textDim),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _art() {
    switch (entry.kind) {
      case MediaKind.folder:
        return Container(
          color: TvColors.card,
          child: const Center(
            child: Icon(Icons.folder_rounded, size: 58, color: Color(0xFFE8B84B)),
          ),
        );

      case MediaKind.image:
        final r = ref;
        if (r == null) return _placeholder(Icons.image_not_supported_outlined);
        return CachedNetworkImage(
          imageUrl: r.url,
          httpHeaders: r.headers,
          fit: BoxFit.cover,
          memCacheWidth: thumbWidth,
          maxWidthDiskCache: thumbWidth * 2,
          fadeInDuration: const Duration(milliseconds: 150),
          placeholder: (_, __) => Container(color: TvColors.card),
          errorWidget: (_, __, ___) => _placeholder(Icons.broken_image_outlined),
        );

      case MediaKind.video:
        final r = ref;
        if (r == null) return _placeholder(Icons.movie_outlined);
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
                errorBuilder: (_, __, ___) => _placeholder(Icons.movie_outlined),
              );
            }
            if (snap.connectionState == ConnectionState.done) {
              return _placeholder(Icons.movie_outlined);
            }
            return Container(
              color: TvColors.card,
              child: const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
            );
          },
        );

      case MediaKind.audio:
        return Container(
          color: TvColors.card,
          child: const Center(
            child: Icon(Icons.music_note_rounded, size: 54, color: TvColors.accent),
          ),
        );

      case MediaKind.other:
        return _placeholder(Icons.insert_drive_file_outlined);
    }
  }

  Widget _placeholder(IconData icon) => Container(
        color: TvColors.card,
        child: Center(child: Icon(icon, size: 46, color: TvColors.textDim)),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: alpha(Colors.black, 0.55),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 18, color: Colors.white),
      );
}
