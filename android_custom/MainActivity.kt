package __PACKAGE__

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * StudyHub TV 的安卓入口。
 *
 * 原生代码只做 Dart 做不了的三件事：
 *   1. **视频抽帧**（studyhubtv/thumb）
 *      Dart 里没有能解 mp4/mkv 的库；而安卓自带的 MediaMetadataRetriever
 *      一行就能拿到某一帧，而且支持直接吃 http(s) 地址 + 请求头 ——
 *      正好能带上 WebDAV 的 Basic Auth，不用先把整集电视剧下到本地。
 *
 *   2. **系统能力**（studyhubtv/system）——「工具」里的应用管理 / 内存清理 /
 *      自启动管理 / 打开本地文件。这些全都要 PackageManager、ActivityManager、
 *      Intent 才能做，MethodChannel 是唯一通路。
 *
 *   3. **文件共享**：安卓 7 以后不许把 file:// 直接交给别的应用
 *      （FileUriExposedException），下载好的 APK 要装、视频要投给系统播放器，
 *      都必须先包成 content:// —— 用 FileProvider 转一道。
 *
 * 为什么不引第三方插件：
 *   这类插件（video_thumbnail / device_apps / open_file 等）在这两年的
 *   Flutter 版本上反复出现"和 compileSdk 对不上 / 用了被删掉的 v1 插件 API"
 *   的问题，而这些能力用系统 API 几十行就写完了，引依赖反而更脆。
 *
 * 线程模型：
 *   MediaMetadataRetriever 抓网络视频、getInstalledApplications 列几十个应用
 *   都是**阻塞**的，放主线程会让界面卡住。统一丢到线程池，结果 post 回主线程
 *   （MethodChannel 的 result 按约定必须在主线程调用）。
 */
class MainActivity : FlutterActivity() {

    private val worker = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, THUMB_CHANNEL).setMethodCallHandler { call, result ->
            handleThumb(call, result)
        }
        MethodChannel(messenger, SYSTEM_CHANNEL).setMethodCallHandler { call, result ->
            handleSystem(call, result)
        }
    }

    // =================================================================
    // 一、抽帧通道
    // =================================================================

    private fun handleThumb(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "frame") {
            result.notImplemented()
            return
        }

        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.success(null)
            return
        }
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val width = call.argument<Int>("width") ?: 480

        // result 只能回调一次：抽帧过程中如果抛异常，catch 里会回调 null，
        // 外层就不能再回调一遍，否则 Flutter 侧会报 "Reply already submitted"。
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

    // =================================================================
    // 二、系统通道（工具里的应用管理 / 内存清理 / 自启动 / 打开文件）
    // =================================================================

    private fun handleSystem(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "apps" -> worker.execute {
                val list: List<Map<String, Any?>> = try {
                    listApps()
                } catch (t: Throwable) {
                    emptyList()
                }
                main.post { result.success(list) }
            }

            "memory" -> worker.execute {
                val info: Map<String, Any?>? = try {
                    memoryInfo()
                } catch (t: Throwable) {
                    null
                }
                main.post { result.success(info) }
            }

            "clearCache" -> worker.execute {
                val freed = try {
                    wipe(cacheDir) + wipe(externalCacheDir)
                } catch (t: Throwable) {
                    0L
                }
                Runtime.getRuntime().gc()
                main.post { result.success(freed) }
            }

            "uninstall" -> {
                val pkg = call.argument<String>("package")
                main.post { result.success(uninstall(pkg)) }
            }

            "launch" -> {
                val pkg = call.argument<String>("package")
                main.post { result.success(launch(pkg)) }
            }

            "appInfo" -> {
                val pkg = call.argument<String>("package") ?: packageName
                main.post { result.success(openAppInfo(pkg)) }
            }

            "openFile" -> {
                val path = call.argument<String>("path")
                main.post { result.success(openLocalFile(path)) }
            }

            "openAutostart" -> main.post { result.success(openAutostart()) }

            else -> result.notImplemented()
        }
    }

    /** 已安装应用列表。图标按 96px PNG 直接带回来，Dart 侧 Image.memory 就能画。 */
    private fun listApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val infos = pm.getInstalledApplications(0)
        val out = ArrayList<Map<String, Any?>>(infos.size)

        for (info in infos) {
            val label = try {
                pm.getApplicationLabel(info).toString()
            } catch (t: Throwable) {
                info.packageName
            }
            val icon = try {
                drawableToPng(info.loadIcon(pm), 96)
            } catch (t: Throwable) {
                null
            }
            out.add(
                mapOf(
                    "package" to info.packageName,
                    "label" to label,
                    "system" to ((info.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                    "self" to (info.packageName == packageName),
                    "icon" to icon,
                )
            )
        }

        // 第三方应用排前面（用户更可能去卸载它们），组内按名字排
        out.sortWith(
            compareBy<Map<String, Any?>>(
                { it["system"] as Boolean },
                { (it["label"] as String) }
            )
        )
        return if (out.size > 400) out.subList(0, 400) else out
    }

    /** 把 Drawable 画成固定尺寸的 PNG 字节（很多应用图标是自绘 Drawable，不是 Bitmap） */
    private fun drawableToPng(d: Drawable?, size: Int): ByteArray? {
        if (d == null) return null
        val bmp: Bitmap = if (d is BitmapDrawable && d.bitmap != null) {
            d.bitmap
        } else {
            val b = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            d.setBounds(0, 0, size, size)
            d.draw(c)
            b
        }
        val scaled = if (bmp.width != size || bmp.height != size) {
            try {
                Bitmap.createScaledBitmap(bmp, size, size, true)
            } catch (t: Throwable) {
                bmp
            }
        } else {
            bmp
        }
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
        if (scaled !== bmp) {
            try {
                scaled.recycle()
            } catch (_: Throwable) {
            }
        }
        return out.toByteArray()
    }

    private fun uninstall(pkg: String?): Boolean {
        if (pkg.isNullOrEmpty() || pkg == packageName) return false
        return try {
            val i = Intent(Intent.ACTION_DELETE, Uri.parse("package:$pkg"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (t: Throwable) {
            false
        }
    }

    private fun launch(pkg: String?): Boolean {
        if (pkg.isNullOrEmpty()) return false
        return try {
            val i = packageManager.getLaunchIntentForPackage(pkg) ?: return false
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (t: Throwable) {
            false
        }
    }

    private fun openAppInfo(pkg: String): Boolean {
        return try {
            val i = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:$pkg"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * 用系统应用打开一个本地文件（下载好的 APK 走这里安装）。
     *
     * 目录在 Android/data/<包名>/files 下 —— 安卓 7 以后 file:// 交给别的应用
     * 会直接抛 FileUriExposedException，所以必须过 FileProvider 换成 content://，
     * 并用 FLAG_GRANT_READ_URI_PERMISSION 把读权限临时借给目标应用。
     */
    private fun openLocalFile(path: String?): Boolean {
        if (path.isNullOrEmpty()) return false
        val f = File(path)
        if (!f.exists()) return false
        return try {
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
            val i = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, mimeOf(f.extension.lowercase()))
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (t: Throwable) {
            false
        }
    }

    private fun mimeOf(ext: String): String = when (ext) {
        "apk" -> "application/vnd.android.package-archive"
        "jpg", "jpeg", "png", "gif", "webp", "bmp" -> "image/*"
        "mp4", "mkv", "avi", "ts", "mov", "wmv", "flv", "rmvb", "webm", "mpg" -> "video/*"
        "mp3", "flac", "wav", "aac", "m4a", "ogg", "opus" -> "audio/*"
        "txt", "log", "json", "xml", "m3u" -> "text/plain"
        else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
    }

    /**
     * 内存信息。
     *
     * 注意 availMem 是**系统当前可用**（不是本应用占用）。电视盒子上 2G 内存
     * 开机就吃掉 1.4G 是常态，把这个数字摆出来，用户才明白"不是我占的"。
     */
    private fun memoryInfo(): Map<String, Any?> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        val rt = Runtime.getRuntime()
        return mapOf(
            "avail" to mi.availMem,
            "total" to mi.totalMem,
            "low" to mi.lowMemory,
            "threshold" to mi.threshold,
            "appUsed" to (rt.totalMemory() - rt.freeMemory()),
            "appMax" to rt.maxMemory(),
        )
    }

    /** 递归删空一个目录（只删内容，保留目录本身），返回释放的字节数 */
    private fun wipe(dir: File?): Long {
        if (dir == null || !dir.exists()) return 0L
        var freed = 0L
        val kids = dir.listFiles() ?: return 0L
        for (f in kids) {
            freed += if (f.isDirectory) {
                val sub = wipe(f)
                try {
                    f.delete()
                } catch (_: Throwable) {
                }
                sub
            } else {
                val n = f.length()
                val ok = try {
                    f.delete()
                } catch (t: Throwable) {
                    false
                }
                if (ok) n else 0L
            }
        }
        return freed
    }

    /**
     * 打开系统自带的自启动管理页。
     *
     * 安卓没有统一的 API（5 到 14 都没有），每家 ROM 自己藏了个 Activity，
     * 只能按包名去猜。猜中就直接进；一个都没猜中（原生 AOSP 的电视盒子
     * 就是这种）就退回本应用的详情页 —— 那里至少能看到权限，用户也知道该
     * 去哪儿找了。
     *
     * 返回：成功的组件名；全失败返回空字符串。
     */
    private fun openAutostart(): String {
        for (name in AUTOSTART_PAGES) {
            val parts = name.split("/")
            if (parts.size != 2) continue
            val pkg = parts[0]
            val cls = if (parts[1].startsWith(".")) pkg + parts[1] else parts[1]
            try {
                val i = Intent()
                    .setComponent(ComponentName(pkg, cls))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(i)
                return name
            } catch (t: Throwable) {
                // 这家 ROM 没有这个页面，继续试下一个
            }
        }
        openAppInfo(packageName)
        return ""
    }

    override fun onDestroy() {
        try {
            worker.shutdownNow()
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }

    companion object {
        private const val THUMB_CHANNEL = "studyhubtv/thumb"
        private const val SYSTEM_CHANNEL = "studyhubtv/system"

        /** 各厂商自启动管理页。顺序无所谓，挨个试，谁在就用谁。 */
        private val AUTOSTART_PAGES = listOf(
            "com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity",
            "com.huawei.systemmanager/.startupmgr.ui.StartupNormalAppListActivity",
            "com.coloros.safecenter/.permission.startup.StartupAppListActivity",
            "com.oppo.safe/.permission.startup.StartupAppListActivity",
            "com.vivo.permissionmanager/.activity.BgStartUpManagerActivity",
            "com.samsung.android.lool/.activity.BatteryActivity",
            "com.letv.android.letvsafe/.autobootmanage.AutoBootManageActivity",
            "com.qihoo.tv.security/.activity.autoStart.AutoStartActivity",
        )
    }
}
