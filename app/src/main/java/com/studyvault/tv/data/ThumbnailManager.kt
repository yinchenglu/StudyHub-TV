package com.studyvault.tv.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/**
 * 预览图管理。
 *
 * 视频/音频没有现成的缩略图，做法是：把文件开头的一小段（默认 8MB）拉到本地临时文件，
 * 再用系统的 MediaMetadataRetriever 抽第一帧。绝大多数 MP4 / MKV 的元数据都在文件开头，
 * 所以不用整部下载。如果开头抽不到帧（极少数 MP4 的 moov 在文件尾部），
 * 且文件不超过 80MB，才整体下载一次重试；再不行就显示占位图。
 */
object ThumbnailManager {

    private const val IMAGE_MAX_BYTES = 24 * 1024 * 1024
    private const val AUDIO_HEAD_BYTES = 3 * 1024 * 1024
    private const val VIDEO_HEAD_BYTES = 8 * 1024 * 1024
    private const val VIDEO_FULL_LIMIT = 80L * 1024 * 1024
    private const val TARGET_WIDTH = 480

    private val POSTER_NAMES = setOf(
        "poster", "folder", "cover", "thumb", "front", "default", "banner", "fanart"
    )

    private val memory: LruCache<String, Bitmap> by lazy {
        val maxKb = (Runtime.getRuntime().maxMemory() / 1024 / 8).toInt().coerceAtLeast(4 * 1024)
        object : LruCache<String, Bitmap>(maxKb) {
            override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount / 1024
        }
    }

    fun cacheKey(uri: String, size: Long, mtime: Long): String = md5("$uri|$size|$mtime")

    fun peek(key: String): Bitmap? = memory.get(key)

    fun clear(context: Context) {
        memory.evictAll()
        try {
            thumbDir(context).listFiles()?.forEach { it.delete() }
        } catch (e: Exception) {
            // ignore
        }
    }

    fun cacheSizeBytes(context: Context): Long {
        var total = 0L
        try {
            thumbDir(context).listFiles()?.forEach { total += it.length() }
        } catch (e: Exception) {
            // ignore
        }
        return total
    }

    private fun thumbDir(context: Context): File {
        val dir = File(context.cacheDir, "thumbs")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    /** 网格里的缩略图 */
    suspend fun load(context: Context, source: RemoteSource, file: RemoteFile): Bitmap? =
        withContext(Dispatchers.IO) { loadBlocking(context, source, file) }

    private fun loadBlocking(context: Context, source: RemoteSource, file: RemoteFile): Bitmap? {
        val key = cacheKey(file.uri, file.size, file.lastModified)

        memory.get(key)?.let { return it }

        val disk = File(thumbDir(context), key)
        if (disk.exists() && disk.length() > 0L) {
            val cached = try {
                BitmapFactory.decodeFile(disk.absolutePath)
            } catch (e: Throwable) {
                null
            }
            if (cached != null) {
                memory.put(key, cached)
                return cached
            }
            disk.delete()
        }

        val bitmap = try {
            when {
                file.isImage -> loadImageThumb(source, file)
                file.isVideo -> loadVideoThumb(context, source, file)
                file.isAudio -> loadAudioThumb(context, source, file)
                file.isDirectory -> loadFolderPoster(context, source, file)
                else -> null
            }
        } catch (e: Throwable) {
            null
        }

        if (bitmap != null) {
            memory.put(key, bitmap)
            try {
                FileOutputStream(disk).use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 82, out)
                }
            } catch (e: Exception) {
                // 缓存写失败不影响显示
            }
        }
        return bitmap
    }

    private fun loadImageThumb(source: RemoteSource, file: RemoteFile): Bitmap? {
        val limit = if (file.size in 1..IMAGE_MAX_BYTES.toLong()) file.size.toInt() else IMAGE_MAX_BYTES
        val bytes = source.read(file.path, 0L, limit)
        if (bytes.isEmpty()) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        if (bounds.outWidth > 0) {
            while (bounds.outWidth / (sample * 2) >= TARGET_WIDTH) sample *= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
    }

    private fun loadVideoThumb(context: Context, source: RemoteSource, file: RemoteFile): Bitmap? {
        val tmp = File(context.cacheDir, "vthumb_${System.nanoTime()}.tmp")
        try {
            val head = source.read(file.path, 0L, VIDEO_HEAD_BYTES)
            if (head.isNotEmpty()) {
                tmp.writeBytes(head)
                extractFrame(tmp)?.let { return it }
            }
            // 首段抽不到帧，文件不大的话整体拉下来再试一次
            if (file.size in 1..VIDEO_FULL_LIMIT) {
                try {
                    source.openStream(file.path, 0L).use { input ->
                        FileOutputStream(tmp).use { out -> input.copyTo(out, 64 * 1024) }
                    }
                    extractFrame(tmp)?.let { return it }
                } catch (e: Exception) {
                    // ignore
                }
            }
            return null
        } finally {
            try {
                tmp.delete()
            } catch (e: Exception) {
                // ignore
            }
        }
    }

    private fun extractFrame(file: File): Bitmap? {
        if (!file.exists() || file.length() <= 0L) return null
        var retriever: MediaMetadataRetriever? = null
        try {
            val r = MediaMetadataRetriever()
            retriever = r
            r.setDataSource(file.absolutePath)
            val times = longArrayOf(1_500_000L, 5_000_000L, 500_000L, 0L)
            for (t in times) {
                val frame = try {
                    r.getFrameAtTime(t, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                } catch (e: Exception) {
                    null
                }
                if (frame != null) return scaleDown(frame)
            }
            return null
        } catch (e: Exception) {
            return null
        } finally {
            try {
                retriever?.release()
            } catch (e: Exception) {
                // ignore
            }
        }
    }

    private fun loadAudioThumb(context: Context, source: RemoteSource, file: RemoteFile): Bitmap? {
        val tmp = File(context.cacheDir, "athumb_${System.nanoTime()}.tmp")
        try {
            val limit = if (file.size in 1..AUDIO_HEAD_BYTES.toLong()) file.size.toInt() else AUDIO_HEAD_BYTES
            val head = source.read(file.path, 0L, limit)
            if (head.isEmpty()) return null
            tmp.writeBytes(head)

            var retriever: MediaMetadataRetriever? = null
            try {
                val r = MediaMetadataRetriever()
                retriever = r
                r.setDataSource(tmp.absolutePath)
                val pic = r.embeddedPicture
                if (pic == null || pic.isEmpty()) return null
                val bmp = BitmapFactory.decodeByteArray(pic, 0, pic.size) ?: return null
                return scaleDown(bmp)
            } catch (e: Exception) {
                return null
            } finally {
                try {
                    retriever?.release()
                } catch (e: Exception) {
                    // ignore
                }
            }
        } finally {
            try {
                tmp.delete()
            } catch (e: Exception) {
                // ignore
            }
        }
    }

    /** 文件夹里如果放了 poster.jpg / folder.jpg 之类，就拿来当封面 */
    private fun loadFolderPoster(context: Context, source: RemoteSource, dir: RemoteFile): Bitmap? {
        return try {
            val children = source.list(dir.path)
            val poster = children.firstOrNull { child ->
                !child.isDirectory &&
                    child.ext in IMAGE_EXT &&
                    child.name.substringBeforeLast('.').lowercase() in POSTER_NAMES
            } ?: return null
            loadImageThumb(source, poster)
        } catch (e: Exception) {
            null
        }
    }

    /** 图片查看器用：按需流式解码，避免大图撑爆内存 */
    suspend fun loadFull(
        source: RemoteSource,
        file: RemoteFile,
        reqWidth: Int,
        reqHeight: Int
    ): Bitmap? = withContext(Dispatchers.IO) {
        try {
            val head = source.read(file.path, 0L, 512 * 1024)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            if (head.isNotEmpty()) {
                BitmapFactory.decodeByteArray(head, 0, head.size, bounds)
            }
            var sample = 1
            val w = bounds.outWidth
            val h = bounds.outHeight
            if (w > 0 && h > 0) {
                while (w / (sample * 2) >= reqWidth && h / (sample * 2) >= reqHeight) sample *= 2
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            source.openStream(file.path, 0L).use { input ->
                BitmapFactory.decodeStream(input, null, opts)
            }
        } catch (e: Throwable) {
            null
        }
    }

    private fun scaleDown(src: Bitmap): Bitmap {
        if (src.width <= TARGET_WIDTH) return src
        val ratio = TARGET_WIDTH.toFloat() / src.width
        val targetH = (src.height * ratio).toInt().coerceAtLeast(1)
        return try {
            val scaled = Bitmap.createScaledBitmap(src, TARGET_WIDTH, targetH, true)
            if (scaled !== src) src.recycle()
            scaled
        } catch (e: Throwable) {
            src
        }
    }

    private fun md5(text: String): String {
        return try {
            val digest = MessageDigest.getInstance("MD5").digest(text.toByteArray(Charsets.UTF_8))
            val sb = StringBuilder(digest.size * 2)
            for (b in digest) {
                sb.append(String.format("%02x", b.toInt() and 0xFF))
            }
            sb.toString()
        } catch (e: Exception) {
            text.hashCode().toString()
        }
    }

    private val IMAGE_EXT = setOf("jpg", "jpeg", "png", "webp", "bmp")
}
