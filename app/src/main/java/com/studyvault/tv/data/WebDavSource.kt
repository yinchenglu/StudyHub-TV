package com.studyvault.tv.data

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.IOException
import java.io.InputStream
import java.io.StringReader
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

/**
 * WebDAV 数据源：目录列举走 PROPFIND，文件读取走 HTTP Range。
 * 播放时直接交给 ExoPlayer 的 HTTP 数据源（带 Basic 认证头），性能最好。
 */
class WebDavSource(override val account: ServerAccount) : RemoteSource {

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private val authHeader: String? = if (account.username.isNotEmpty()) {
        Credentials.basic(account.username, account.password, Charsets.UTF_8)
    } else {
        null
    }

    private fun scheme(): String = if (account.https) "https" else "http"

    private fun urlOf(path: String): String {
        val sb = StringBuilder()
        sb.append(scheme()).append("://").append(account.host)
        val defaultPort = if (account.https) 443 else 80
        if (account.port != defaultPort) sb.append(':').append(account.port)
        val segments = path.trim('/').split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty()) sb.append('/')
        else segments.forEach { sb.append('/').append(Uri.encode(it)) }
        return sb.toString()
    }

    private fun newRequest(url: String): Request.Builder {
        val b = Request.Builder().url(url)
        authHeader?.let { b.header("Authorization", it) }
        return b
    }

    override fun list(path: String): List<RemoteFile> {
        val url = urlOf(path)
        val body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<d:propfind xmlns:d=\"DAV:\"><d:prop>" +
            "<d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/>" +
            "</d:prop></d:propfind>"
        val request = newRequest(url)
            .method("PROPFIND", body.toRequestBody("application/xml; charset=utf-8".toMediaType()))
            .header("Depth", "1")
            .build()

        client.newCall(request).execute().use { response ->
            val code = response.code
            if (code != 207 && !response.isSuccessful) {
                throw IOException("服务器返回 HTTP $code")
            }
            val xml = response.body?.string().orEmpty()
            return parsePropfind(xml, path)
        }
    }

    private fun parsePropfind(xml: String, basePath: String): List<RemoteFile> {
        val out = ArrayList<RemoteFile>()
        val parser = XmlPullParserFactory.newInstance().newPullParser()
        parser.setInput(StringReader(xml))

        var href: String? = null
        var isCollection = false
        var length = 0L
        var lastModified = 0L
        var inResponse = false
        var currentTag = ""

        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> {
                    currentTag = parser.name.lowercase(Locale.ROOT)
                    if (currentTag.endsWith("response")) {
                        inResponse = true
                        href = null
                        isCollection = false
                        length = 0L
                        lastModified = 0L
                    } else if (currentTag.endsWith("collection")) {
                        isCollection = true
                    }
                }

                XmlPullParser.TEXT -> {
                    if (inResponse) {
                        val text = parser.text ?: ""
                        when {
                            currentTag.endsWith("href") -> href = text.trim()
                            currentTag.endsWith("getcontentlength") ->
                                length = text.trim().toLongOrNull() ?: 0L
                            currentTag.endsWith("getlastmodified") ->
                                lastModified = parseHttpDate(text.trim())
                        }
                    }
                }

                XmlPullParser.END_TAG -> {
                    val tag = parser.name.lowercase(Locale.ROOT)
                    if (tag.endsWith("response")) {
                        inResponse = false
                        val raw = href
                        if (!raw.isNullOrEmpty()) {
                            val item = toRemoteFile(raw, basePath, isCollection, length, lastModified)
                            if (item != null) out.add(item)
                        }
                    }
                }
            }
            event = parser.next()
        }

        out.sortWith(compareByDescending<RemoteFile> { it.isDirectory }.thenBy { it.name.lowercase() })
        return out
    }

    private fun toRemoteFile(
        rawHref: String,
        basePath: String,
        isCollection: Boolean,
        length: Long,
        lastModified: Long
    ): RemoteFile? {
        var decoded = try {
            Uri.parse(rawHref).path ?: rawHref
        } catch (e: Exception) {
            rawHref
        }
        if (decoded.isEmpty()) return null

        // 有些服务器返回的是相对路径，补上前缀
        if (!decoded.startsWith("/")) {
            val base = if (basePath.endsWith("/")) basePath else "$basePath/"
            decoded = base + decoded
        }

        var clean = decoded
        if (clean.length > 1 && clean.endsWith("/")) clean = clean.dropLast(1)

        val normalizedBase = if (basePath.length > 1 && basePath.endsWith("/")) basePath.dropLast(1) else basePath
        if (clean == normalizedBase) return null // 自身条目，跳过

        val name = clean.substringAfterLast('/')
        if (name.isEmpty()) return null

        return RemoteFile(
            name = name,
            path = clean,
            isDirectory = isCollection,
            size = if (isCollection) 0L else length,
            lastModified = lastModified,
            uri = urlOf(clean)
        )
    }

    override fun size(path: String): Long {
        val request = newRequest(urlOf(path)).head().build()
        client.newCall(request).execute().use { response ->
            return response.header("Content-Length")?.toLongOrNull() ?: 0L
        }
    }

    override fun read(path: String, offset: Long, length: Int): ByteArray {
        if (length <= 0) return ByteArray(0)
        val end = offset + length - 1
        val request = newRequest(urlOf(path))
            .header("Range", "bytes=$offset-$end")
            .build()
        client.newCall(request).execute().use { response ->
            if (response.code != 206 && !response.isSuccessful) {
                throw IOException("服务器返回 HTTP ${response.code}")
            }
            return response.body?.bytes() ?: ByteArray(0)
        }
    }

    override fun openStream(path: String, offset: Long): InputStream {
        val request = if (offset > 0) {
            newRequest(urlOf(path)).header("Range", "bytes=$offset-").build()
        } else {
            newRequest(urlOf(path)).build()
        }
        val response = client.newCall(request).execute()
        val body = response.body ?: throw IOException("响应为空")
        return body.byteStream()
    }

    override fun uriOf(path: String): String = urlOf(path)

    override fun dataSourceFactory(): DataSource.Factory {
        val headers = HashMap<String, String>()
        authHeader?.let { headers["Authorization"] = it }
        return DefaultHttpDataSource.Factory()
            .setDefaultRequestProperties(headers)
            .setConnectTimeoutMs(15000)
            .setReadTimeoutMs(30000)
            .setAllowCrossProtocolRedirects(true)
    }

    override fun close() {
        try {
            client.dispatcher.executorService.shutdown()
            client.connectionPool.evictAll()
        } catch (e: Exception) {
            // ignore
        }
    }

    private fun parseHttpDate(text: String): Long {
        if (text.isEmpty()) return 0L
        val patterns = arrayOf(
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd HH:mm:ss"
        )
        for (p in patterns) {
            try {
                val sdf = SimpleDateFormat(p, Locale.US)
                if (p.contains("zzz")) sdf.timeZone = TimeZone.getTimeZone("GMT")
                if (p.endsWith("'Z'")) sdf.timeZone = TimeZone.getTimeZone("UTC")
                val d = sdf.parse(text)
                if (d != null) return d.time
            } catch (e: Exception) {
                // 换下一种格式
            }
        }
        return 0L
    }
}
