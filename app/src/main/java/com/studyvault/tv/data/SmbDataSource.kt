package com.studyvault.tv.data

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSpec
import jcifs.smb.SmbRandomAccessFile
import java.io.IOException

/**
 * 让 ExoPlayer 能直接播 SMB 上的文件：把 DataSpec 的区间读转发给 jcifs 的随机读。
 * 这样就不用先把整部电影下载到本地，边下边播。
 */
class SmbDataSource(private val source: SmbSource) : BaseDataSource(true) {

    private var raf: SmbRandomAccessFile? = null
    private var currentUri: Uri? = null
    private var bytesRemaining: Long = 0L
    private var opened: Boolean = false

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        currentUri = dataSpec.uri

        // uri.path 已经是解码后的： /共享名/子路径
        val decoded = dataSpec.uri.path ?: throw IOException("无效的地址: ${dataSpec.uri}")
        val segments = decoded.trimStart('/').split('/').filter { it.isNotEmpty() }
        // 第一段是共享名，去掉后就是内部的相对路径
        val internalPath = "/" + segments.drop(1).joinToString("/")

        val file = source.fileOf(internalPath)
        val total = try {
            file.length()
        } catch (e: Exception) {
            throw IOException("无法读取文件信息: ${e.message}", e)
        }

        val position = if (dataSpec.position < 0) 0L else dataSpec.position
        val r = try {
            SmbRandomAccessFile(file, "r")
        } catch (e: Exception) {
            throw IOException("打开文件失败: ${e.message}", e)
        }
        r.seek(position)
        raf = r

        bytesRemaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) {
            dataSpec.length
        } else {
            (total - position).coerceAtLeast(0L)
        }
        opened = true
        transferStarted(dataSpec)
        return bytesRemaining
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT
        val toRead = minOf(length.toLong(), bytesRemaining).toInt()
        val handle = raf ?: return C.RESULT_END_OF_INPUT
        val n = try {
            handle.read(buffer, offset, toRead)
        } catch (e: Exception) {
            throw IOException("读取失败: ${e.message}", e)
        }
        if (n <= 0) return C.RESULT_END_OF_INPUT
        bytesRemaining -= n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = currentUri

    override fun close() {
        try {
            raf?.close()
        } catch (e: Exception) {
            // ignore
        } finally {
            raf = null
            currentUri = null
            if (opened) {
                opened = false
                transferEnded()
            }
        }
    }
}
