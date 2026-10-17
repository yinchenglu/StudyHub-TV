package __PACKAGE__

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * StudyHub TV 的安卓入口。
 *
 * 整个 App 只有一处需要原生代码：**视频抽帧**。
 *
 * 为什么非得原生：
 *   Dart 里没有能解 mp4/mkv 的库；而安卓系统自带的 MediaMetadataRetriever
 *   一行就能拿到某一帧，而且支持直接吃 http(s) 地址 + 请求头 ——
 *   正好能带上 WebDAV 的 Basic Auth，不用先把整集电视剧下到本地。
 *
 * 为什么不引第三方插件：
 *   这类插件（video_thumbnail 等）在这两年的 Flutter 版本上反复出现
 *   "和 compileSdk 对不上 / 用了被删掉的 v1 插件 API"的问题，
 *   而这种能力用系统 API 20 行就写完了，引依赖反而更脆。
 *
 * 线程模型：
 *   MediaMetadataRetriever 抓取网络视频是**阻塞**的（要发请求、要等首帧），
 *   放在主线程会让整个界面卡住，所以丢到自己维护的线程池里跑，
 *   结果再 post 回主线程（MethodChannel 的 result 必须在主线程调用）。
 *   线程数刻意设成 2：和 Dart 侧的 ThumbCache 并发闸门保持一致，
 *   再多只会让电视盒子的解码器排队，并不会更快。
 */
class MainActivity : FlutterActivity() {

    private val worker = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "frame") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val url = call.argument<String>("url")
                if (url.isNullOrEmpty()) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                val width = call.argument<Int>("width") ?: 480

                // result 只能回调一次：抽帧过程中如果抛异常，catch 里会回调 null，
                // 外层就不能再回调一遍，否则 Flutter 侧会报
                // "Reply already submitted"。
                val replied = AtomicBoolean(false)
                val reply = { bytes: ByteArray? ->
                    if (replied.compareAndSet(false, true)) {
                        main.post { result.success(bytes) }
                    }
                }

                worker.execute {
                    val bytes = try {
                        extractFrame(url, headers, width)
                    } catch (t: Throwable) {
                        null
                    }
                    reply(bytes)
                }
            }
    }

    /**
     * 抓一帧、缩放到指定宽度、压成 JPEG。
     *
     * 抓取时间点的选择：优先第 1 秒。
     * 直接用第 0 帧的话，很多片子开头是纯黑的两秒（或台标），
     * 抽出来就是一整块黑，等于没封面。第 1 秒能躲掉大部分情况。
     */
    private fun extractFrame(
        url: String,
        headers: Map<String, String>,
        targetWidth: Int,
    ): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(url, headers)

            val raw: Bitmap =
                retriever.getFrameAtTime(1_000_000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: retriever.getFrameAtTime()
                    ?: return null

            val w = raw.width
            val h = raw.height
            val frame: Bitmap = if (w > targetWidth && w > 0 && h > 0) {
                val newH = (h.toFloat() * targetWidth / w).toInt().coerceAtLeast(1)
                val scaled = Bitmap.createScaledBitmap(raw, targetWidth, newH, true)
                if (scaled !== raw) raw.recycle()
                scaled
            } else {
                raw
            }

            val out = ByteArrayOutputStream()
            frame.compress(Bitmap.CompressFormat.JPEG, 82, out)
            frame.recycle()
            return out.toByteArray()
        } finally {
            try {
                retriever.release()
            } catch (_: Throwable) {
            }
        }
    }

    override fun onDestroy() {
        try {
            worker.shutdownNow()
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "studyhubtv/thumb"
    }
}
