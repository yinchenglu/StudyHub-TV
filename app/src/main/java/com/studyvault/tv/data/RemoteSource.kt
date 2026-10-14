package com.studyvault.tv.data

import androidx.media3.datasource.DataSource
import java.io.InputStream

/**
 * 统一的远程文件访问接口，SMB 与 WebDAV 各实现一份。
 * 所有 path 都是「相对于连接根」的路径，以 / 开头，例如 /电影/流浪地球.mkv
 */
interface RemoteSource {

    val account: ServerAccount

    /** 列出某个目录 */
    fun list(path: String): List<RemoteFile>

    /** 文件大小 */
    fun size(path: String): Long

    /** 读取指定区间（预览图取首段字节用） */
    fun read(path: String, offset: Long, length: Int): ByteArray

    /** 从指定偏移开始读的流 */
    fun openStream(path: String, offset: Long): InputStream

    /** 把路径转成播放器可用的 uri */
    fun uriOf(path: String): String

    /** SMB 需要自定义数据源；返回 null 表示交给 ExoPlayer 用默认 HTTP 数据源 */
    fun dataSourceFactory(): DataSource.Factory?

    fun close()
}
