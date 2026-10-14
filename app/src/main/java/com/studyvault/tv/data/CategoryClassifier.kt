package com.studyvault.tv.data

import java.util.Locale

/** 主界面左侧的分类 */
enum class MediaCategory(val key: String, val label: String) {
    IMAGE("image", "图片"),
    VIDEO("video", "视频"),
    AUDIO("audio", "音频"),
    MOVIE("movie", "电影"),
    TVSHOW("tvshow", "电视剧"),
    ALL("all", "全部文件")
}

/**
 * 固定文件夹自动识别：用关键词去匹配服务器上的文件夹名（不区分大小写）。
 * 关键词可以在设置里扩展，这里是默认规则。
 */
object CategoryClassifier {

    private val KEYWORDS: Map<MediaCategory, List<String>> = mapOf(
        MediaCategory.IMAGE to listOf(
            "photo", "photos", "picture", "pictures", "image", "images",
            "dcim", "camera", "screenshot", "wallpaper",
            "照片", "图片", "相册", "图库", "壁纸", "摄影"
        ),
        MediaCategory.VIDEO to listOf(
            "video", "videos", "clip", "clips", "homevideo", "camera",
            "视频", "录像", "短片", "摄录"
        ),
        MediaCategory.AUDIO to listOf(
            "music", "audio", "song", "songs", "mp3", "flac", "podcast", "audiobook",
            "音乐", "音频", "歌曲", "有声", "播客"
        ),
        MediaCategory.MOVIE to listOf(
            "movie", "movies", "film", "films", "bluray", "blu-ray", "remux", "cinema",
            "电影", "影片", "蓝光", "原盘", "影院"
        ),
        MediaCategory.TVSHOW to listOf(
            "tvshow", "tvshows", "tv show", "tv shows", "series", "show", "shows",
            "anime", "drama", "variety",
            "电视剧", "剧集", "美剧", "英剧", "日剧", "韩剧", "港剧", "台剧",
            "综艺", "动漫", "番剧", "连续剧"
        )
    )

    /**
     * 根据文件夹名猜测分类。
     * 规则：先精确匹配；再做「包含」匹配（拉丁关键词至少 3 个字符，避免 tv/4k 之类误伤），
     * 命中多个时取关键词更长的那个。
     */
    fun classifyFolderName(rawName: String): MediaCategory? {
        val name = rawName.lowercase(Locale.ROOT).trim()
        if (name.isEmpty()) return null

        var bestCat: MediaCategory? = null
        var bestLen = 0

        for ((cat, words) in KEYWORDS) {
            for (w in words) {
                if (name == w) return cat
            }
        }

        for ((cat, words) in KEYWORDS) {
            for (w in words) {
                val isCjk = w.any { it.code > 0x2E80 }
                if (!isCjk && w.length < 3) continue
                if (name.contains(w) && w.length > bestLen) {
                    bestCat = cat
                    bestLen = w.length
                }
            }
        }
        return bestCat
    }

    fun labelOf(cat: MediaCategory): String = cat.label
}
