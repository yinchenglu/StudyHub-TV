package com.studyvault.tv.data

import android.net.Uri
import androidx.media3.datasource.DataSource
import jcifs.CIFSContext
import jcifs.config.PropertyConfiguration
import jcifs.context.BaseContext
import jcifs.smb.NtlmPasswordAuthenticator
import jcifs.smb.SmbFile
import jcifs.smb.SmbRandomAccessFile
import java.io.InputStream
import java.util.Properties

/**
 * SMB 数据源。
 *
 * 为什么用 jcifs-ng 而不是 smbj：smbj 内部用到 Java 7 的 MethodHandles，
 * 打包时要求 minSdk >= 26，在安卓 5 的盒子上根本装不上。
 * jcifs-ng 是纯 Java 实现、对老安卓友好，Nova 等播放器也在用。
 */
class SmbSource(override val account: ServerAccount) : RemoteSource {

    @Volatile
    private var cachedContext: CIFSContext? = null

    private fun context(): CIFSContext {
        cachedContext?.let { return it }
        synchronized(this) {
            cachedContext?.let { return it }
            val props = Properties()
            props.setProperty("jcifs.smb.client.enableSMB2", "true")
            props.setProperty("jcifs.smb.client.dfs.disabled", "true")
            props.setProperty("jcifs.smb.client.soTimeout", "20000")
            props.setProperty("jcifs.smb.client.connTimeout", "15000")
            props.setProperty("jcifs.smb.client.responseTimeout", "20000")
            props.setProperty("jcifs.smb.client.attrExpirationPeriod", "3000")
            props.setProperty("jcifs.netbios.retryTimeout", "1000")
            props.setProperty("jcifs.resolveOrder", "DNS")
            val base = BaseContext(PropertyConfiguration(props))
            val authed = base.withCredentials(
                NtlmPasswordAuthenticator(account.username, account.password)
            )
            cachedContext = authed
            return authed
        }
    }

    private fun shareName(): String = account.share.trim().trim('/')

    private fun shareRoot(): SmbFile =
        SmbFile("smb://${account.host}/${shareName()}/", context())

    /**
     * 用「父资源共享 + 相对路径」的方式构造 SmbFile，
     * 这样中文、空格等文件名都由 jcifs 自己处理，不会踩 URL 转义的坑。
     */
    fun fileOf(path: String): SmbFile {
        val rel = path.trim().trimStart('/')
        val root = shareRoot()
        return if (rel.isEmpty()) root else SmbFile(root, rel)
    }

    override fun list(path: String): List<RemoteFile> {
        val dir = fileOf(path)
        val children = dir.listFiles() ?: return emptyList()
        val out = ArrayList<RemoteFile>(children.size)
        for (f in children) {
            val rawName = try {
                f.name
            } catch (e: Exception) {
                ""
            }
            val name = rawName.trimEnd('/')
            if (name.isEmpty() || name == "." || name == "..") continue

            val childPath = joinPath(path, name)
            val isDir = try {
                f.isDirectory
            } catch (e: Exception) {
                rawName.endsWith("/")
            }
            out.add(
                RemoteFile(
                    name = name,
                    path = childPath,
                    isDirectory = isDir,
                    size = if (isDir) 0L else safeLength(f),
                    lastModified = try {
                        f.lastModified()
                    } catch (e: Exception) {
                        0L
                    },
                    uri = uriOf(childPath)
                )
            )
        }
        out.sortWith(compareByDescending<RemoteFile> { it.isDirectory }.thenBy { it.name.lowercase() })
        return out
    }

    private fun safeLength(f: SmbFile): Long = try {
        f.length()
    } catch (e: Exception) {
        0L
    }

    override fun size(path: String): Long = try {
        fileOf(path).length()
    } catch (e: Exception) {
        0L
    }

    override fun read(path: String, offset: Long, length: Int): ByteArray {
        if (length <= 0) return ByteArray(0)
        val raf = SmbRandomAccessFile(fileOf(path), "r")
        try {
            raf.seek(offset)
            val buf = ByteArray(length)
            var total = 0
            while (total < length) {
                val n = raf.read(buf, total, length - total)
                if (n <= 0) break
                total += n
            }
            return if (total == length) buf else buf.copyOf(total)
        } finally {
            try {
                raf.close()
            } catch (e: Exception) {
                // ignore
            }
        }
    }

    override fun openStream(path: String, offset: Long): InputStream {
        val raf = SmbRandomAccessFile(fileOf(path), "r")
        raf.seek(offset)
        return object : InputStream() {
            override fun read(): Int {
                val one = ByteArray(1)
                val n = raf.read(one, 0, 1)
                return if (n <= 0) -1 else one[0].toInt() and 0xFF
            }

            override fun read(b: ByteArray, off: Int, len: Int): Int = raf.read(b, off, len)

            override fun close() {
                try {
                    raf.close()
                } catch (e: Exception) {
                    // ignore
                }
            }
        }
    }

    /**
     * 播放器用的 uri：smb://host/共享名/编码后的路径
     * 用 Android 的 Uri 编码，读回来时 Uri.path 会自动解码。
     */
    override fun uriOf(path: String): String {
        val encodedTail = path.trim('/')
            .split('/')
            .filter { it.isNotEmpty() }
            .joinToString("/") { Uri.encode(it) }
        val share = Uri.encode(shareName())
        val tail = if (encodedTail.isEmpty()) "" else "/$encodedTail"
        return "smb://${account.host}/$share$tail"
    }

    override fun dataSourceFactory(): DataSource.Factory = DataSource.Factory { SmbDataSource(this) }

    override fun close() {
        try {
            cachedContext?.close()
        } catch (e: Exception) {
            // ignore
        }
        cachedContext = null
    }

    private fun joinPath(base: String, name: String): String {
        var b = base.trim()
        if (!b.startsWith("/")) b = "/$b"
        while (b.length > 1 && b.endsWith("/")) b = b.dropLast(1)
        return if (b.isEmpty() || b == "/") "/$name" else "$b/$name"
    }
}
