package com.studyvault.tv.data

import com.studyvault.tv.util.Fmt
import java.util.Locale

/** 连接协议 */
enum class ProtocolType(val label: String, val defaultPort: Int) {
    SMB("SMB", 445),
    WEBDAV("WebDAV", 80)
}

/** 一个保存下来的服务器账号 */
data class ServerAccount(
    val id: String,
    val name: String,
    val type: ProtocolType,
    val host: String,
    val port: Int,
    /** SMB 的共享名，例如 media */
    val share: String = "",
    /** 进入账号后默认展示的目录 */
    val rootPath: String = "/",
    val username: String = "",
    val password: String = "",
    val https: Boolean = false
) {
    /** 界面上展示的地址 */
    val address: String
        get() = when (type) {
            ProtocolType.SMB -> "smb://$host/$share"
            ProtocolType.WEBDAV -> "${if (https) "https" else "http"}://$host:$port$rootPath"
        }

    /** 把起始目录规范化成 /a/b 形式 */
    fun normalizedRoot(): String {
        var r = rootPath.trim()
        if (r.isEmpty()) r = "/"
        if (!r.startsWith("/")) r = "/$r"
        if (r.length > 1 && r.endsWith("/")) r = r.dropLast(1)
        return r
    }
}

/** 远程目录里的一项 */
data class RemoteFile(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val size: Long,
    val lastModified: Long,
    val uri: String
) {
    val ext: String
        get() {
            val i = name.lastIndexOf('.')
            return if (i >= 0) name.substring(i + 1).lowercase(Locale.ROOT) else ""
        }

    val isImage: Boolean get() = ext in IMAGE_EXT
    val isVideo: Boolean get() = ext in VIDEO_EXT
    val isAudio: Boolean get() = ext in AUDIO_EXT
    val isMedia: Boolean get() = isImage || isVideo || isAudio

    val sizeText: String get() = if (isDirectory) "" else Fmt.size(size)

    companion object {
        val IMAGE_EXT = setOf(
            "jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "avif"
        )
        val VIDEO_EXT = setOf(
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "ts", "m2ts", "m4v", "rmvb",
            "rm", "3gp", "mpg", "mpeg", "webm", "vob", "f4v", "mts", "divx", "asf"
        )
        val AUDIO_EXT = setOf(
            "mp3", "flac", "wav", "aac", "m4a", "ogg", "ape", "wma", "opus", "amr", "mid", "midi"
        )
    }
}
