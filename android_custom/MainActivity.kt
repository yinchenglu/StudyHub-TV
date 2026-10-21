package __PACKAGE__

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.media.tv.TvInputInfo
import android.media.tv.TvInputManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

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

            "openAutostart" -> worker.execute {
                // 索引（全机 Activity）在 worker 里建好，启动动作回主线程做
                activityIndex()
                val hit = try {
                    openAutostart()
                } catch (t: Throwable) {
                    ""
                }
                main.post { result.success(hit) }
            }

            // ---------------- v1.5 新增 ----------------

            "openSystemSettings" -> worker.execute {
                activityIndex()
                val hit = try {
                    openSystemSettings()
                } catch (t: Throwable) {
                    ""
                }
                main.post { result.success(hit) }
            }

            "openInputSource" -> worker.execute {
                activityIndex()
                val hit = try {
                    openInputSource()
                } catch (t: Throwable) {
                    ""
                }
                main.post { result.success(hit) }
            }

            "tvInputs" -> worker.execute {
                val list: List<Map<String, Any?>> = try {
                    listTvInputs()
                } catch (t: Throwable) {
                    emptyList()
                }
                main.post { result.success(list) }
            }

            "bgApps" -> worker.execute {
                val list: List<Map<String, Any?>> = try {
                    listBackgroundApps()
                } catch (t: Throwable) {
                    emptyList()
                }
                main.post { result.success(list) }
            }

            "cleanBackground" -> worker.execute {
                val res: Map<String, Any?> = try {
                    cleanBackgroundApps()
                } catch (t: Throwable) {
                    mapOf("killed" to 0, "before" to 0L, "after" to 0L)
                }
                main.post { result.success(res) }
            }

            "extractApk" -> worker.execute {
                val pkg = call.argument<String>("package")
                val path = try {
                    extractApk(pkg)
                } catch (t: Throwable) {
                    ""
                }
                main.post { result.success(path) }
            }

            "zip" -> worker.execute {
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                val out = call.argument<String>("out") ?: ""
                val n = try {
                    zipPaths(paths, out)
                } catch (t: Throwable) {
                    -1
                }
                main.post { result.success(n) }
            }

            "unzip" -> worker.execute {
                val zipPath = call.argument<String>("zip") ?: ""
                val dir = call.argument<String>("dir") ?: ""
                val n = try {
                    unzipTo(zipPath, dir)
                } catch (t: Throwable) {
                    -1
                }
                main.post { result.success(n) }
            }

            "requestAllFiles" -> main.post { result.success(requestAllFiles()) }

            "storage" -> worker.execute {
                val info: Map<String, Any?> = try {
                    storageInfo()
                } catch (t: Throwable) {
                    emptyMap()
                }
                main.post { result.success(info) }
            }

            "bootApps" -> worker.execute {
                val list: List<Map<String, Any?>> = try {
                    listBootApps()
                } catch (t: Throwable) {
                    emptyList()
                }
                main.post { result.success(list) }
            }

            "setBootEnabled" -> worker.execute {
                val pkg = call.argument<String>("package") ?: ""
                val on = call.argument<Boolean>("enable") ?: false
                val res: Map<String, Any?> = try {
                    setBootEnabled(pkg, on)
                } catch (t: Throwable) {
                    mapOf("ok" to false, "msg" to (t.message ?: "失败"))
                }
                main.post { result.success(res) }
            }

            // ---------------- v1.7 新增：手势用的亮度 / 系统音量 ----------------
            //
            // 亮度改的是**本窗口**的 screenBrightness，不动系统设置：
            //   * 不需要 WRITE_SETTINGS 权限（改系统亮度才需要，还得用户去系统里开）
            //   * 退出播放器/退出 App 自动恢复，不会把用户手机亮度改坏
            //   * 读出来是 -1 表示"跟随系统"，Dart 侧按 50% 起步
            "getBrightness" -> main.post {
                // 必须转 Double：Flutter 的 StandardMessageCodec 不认 Kotlin 的 Float，
                // 直接回 Float 会在 Dart 侧抛 "Unsupported value"
                //
                // screenBrightness = -1 表示"跟随系统"（绝大多数设备打开页面时都是 -1）。
                // 直接把 -1 交给 Dart，滑动手势的起点就是 -1，一拖就从最暗开始，
                // 所以这里读系统的实际亮度值当起点。
                var b = window.attributes.screenBrightness.toDouble()
                if (b < 0) {
                    b = try {
                        Settings.System.getInt(
                            contentResolver,
                            Settings.System.SCREEN_BRIGHTNESS
                        ) / 255.0
                    } catch (t: Throwable) {
                        0.5
                    }
                }
                result.success(b.coerceIn(0.03, 1.0))
            }

            "setBrightness" -> {
                val raw = call.argument<Double>("value") ?: 1.0
                main.post {
                    try {
                        val lp = window.attributes
                        // < 0 = 恢复"跟随系统"（退出播放器时调，别把亮度留在暗档）
                        lp.screenBrightness =
                            if (raw < 0) -1f else raw.toFloat().coerceIn(0.01f, 1.0f)
                        window.attributes = lp
                        result.success(lp.screenBrightness.toDouble())
                    } catch (t: Throwable) {
                        result.success(null)
                    }
                }
            }

            "systemVolume" -> main.post {
                val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                if (am == null) {
                    result.success(null)
                } else {
                    result.success(
                        mapOf(
                            "cur" to am.getStreamVolume(AudioManager.STREAM_MUSIC),
                            "max" to am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                        )
                    )
                }
            }

            "setSystemVolume" -> {
                val raw = call.argument<Int>("value") ?: 0
                main.post {
                    val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                    if (am == null) {
                        result.success(false)
                    } else {
                        try {
                            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            // flags = 0：不弹系统音量条（我们自己画）
                            am.setStreamVolume(
                                AudioManager.STREAM_MUSIC,
                                raw.coerceIn(0, max),
                                0
                            )
                            result.success(true)
                        } catch (t: Throwable) {
                            // 个别电视 ROM 禁止普通应用改音量（抛 SecurityException）
                            result.success(false)
                        }
                    }
                }
            }

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
            if (launchComponent(pkg, cls)) return name
        }
        // 厂商自家页面名字千奇百怪，按关键词全机捞一遍
        val words = listOf(
            "autostart", "auto_start", "startupmgr", "startup", "bootstart",
            "selfstart", "startmanage", "bootlaunch",
            "自启动", "自启", "开机启动", "启动管理", "开机自启",
        )
        for ((pkg, cls) in findByKeywords(words)) {
            if (launchComponent(pkg, cls)) return "kw:$pkg/$cls"
        }
        openAppInfo(packageName)
        return ""
    }

    // =================================================================
    // 三、v1.5 工具增强：系统设置 / 信号源 / 后台清理 / 提包 / 压缩解压 / 自启动
    // =================================================================

    /** 系统设置的各种可能入口（不同 ROM 命中不同的那条） */
    private val SETTINGS_ACTIONS = listOf(
        Settings.ACTION_SETTINGS,                        // android.settings.SETTINGS
        "android.settings.SETTINGS_EMBEDDED_DEEP_LINK",  // 部分国产 TV 用这个
        "com.android.settings.action.SETTINGS",
    )

    /** 信号源 / 输入源的各种可能入口（安卓没有统一 API，只能挨个试） */
    private val INPUT_ACTIONS = listOf(
        "android.settings.TV_INPUT_SETTINGS",
        "android.settings.TV_SETTINGS",
        "android.settings.TV_INPUT_SOURCE",
        "com.hisense.intent.action.SOURCE",              // 海信
        "com.skyworth.intent.action.SOURCE",             // 创维
        "com.tcl.tvsource.ACTION_SOURCE",                // TCL
        "com.letv.tvsource.ACTION_SOURCE",               // 乐视
        "com.mstar.android.intent.action.SOURCE_SWITCH", // MStar 方案（很多盒子）
        "com.mediatek.intent.action.SOURCE_SWITCH",      // MTK 方案
    )

    private fun startSafely(i: Intent): Boolean = try {
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(i)
        true
    } catch (t: Throwable) {
        false
    }

    private fun launchComponent(pkg: String, cls: String): Boolean {
        if (pkg.isEmpty() || cls.isEmpty()) return false
        return startSafely(Intent().setComponent(ComponentName(pkg, cls)))
    }

    /**
     * 全机 Activity 索引（包名 / 类名 / 应用名）。
     *
     * 为什么需要它：国产电视的"系统设置""信号源""自启动管理"根本没有统一的
     * action，甚至不响应 android.settings.SETTINGS —— 它们就是普通的 Activity，
     * 名字叫 TvSourceActivity / AutoStartActivity 之类。既然猜不到 action，
     * 就把全机的 Activity 列出来按关键词找，找到哪个就试哪个。
     * 结果缓存，只扫一次（一两百毫秒），别每次点击都扫。
     */
    private var _index: List<Triple<String, String, String>>? = null

    private fun activityIndex(): List<Triple<String, String, String>> {
        _index?.let { return it }
        val out = ArrayList<Triple<String, String, String>>()
        val pm = packageManager
        try {
            val flags = PackageManager.GET_ACTIVITIES or
                PackageManager.GET_DISABLED_COMPONENTS
            for (pi in pm.getInstalledPackages(flags)) {
                val app = pi.applicationInfo ?: continue
                val label = try {
                    pm.getApplicationLabel(app).toString()
                } catch (t: Throwable) {
                    pi.packageName
                }
                val acts = pi.activities
                if (acts != null) {
                    for (a in acts) {
                        if (!a.exported) continue
                        out.add(Triple(pi.packageName, a.name, label))
                    }
                }
            }
        } catch (_: Throwable) {
        }
        _index = out
        return out
    }

    /** 按关键词找可启动的 Activity：先匹配类名，再匹配应用名（"信号源"这种桌面名） */
    private fun findByKeywords(words: List<String>, limit: Int = 14): List<Pair<String, String>> {
        val idx = activityIndex()
        val hits = ArrayList<Pair<String, String>>()
        val low = words.map { it.lowercase() }

        for ((pkg, cls, _) in idx) {
            if (pkg == packageName) continue
            val c = cls.lowercase()
            if (low.any { it.isNotEmpty() && c.contains(it) }) hits.add(pkg to cls)
            if (hits.size >= limit) return hits
        }
        for ((pkg, cls, label) in idx) {
            if (pkg == packageName) continue
            if (hits.any { it.first == pkg && it.second == cls }) continue
            val l = label.lowercase()
            if (low.any { it.isNotEmpty() && l.contains(it) }) hits.add(pkg to cls)
            if (hits.size >= limit) break
        }
        return hits
    }

    /**
     * 直接打开系统设置首页。
     *
     * 返回命中方式的描述（空字符串 = 全都没命中，只打开了本应用详情页）。
     * 三步走的理由：先试标准 action（AOSP / 大部分盒子），再试显式组件，
     * 最后把包名带 settings 的应用的桌面入口拉起来 —— 厂商改过的 ROM
     * 基本只有最后这条能走通。
     */
    private fun openSystemSettings(): String {
        for (a in SETTINGS_ACTIONS) {
            if (startSafely(Intent(a))) return a
        }
        for (c in listOf(
            "com.android.settings/com.android.settings.Settings",
            "com.android.settings/.Settings",
        )) {
            val parts = c.split("/")
            if (parts.size != 2) continue
            val cls = if (parts[1].startsWith(".")) parts[0] + parts[1] else parts[1]
            if (launchComponent(parts[0], cls)) return c
        }
        val pm = packageManager
        for (pi in pm.getInstalledPackages(0)) {
            val p = pi.packageName.lowercase()
            if (!p.contains("setting")) continue
            val i = pm.getLaunchIntentForPackage(pi.packageName) ?: continue
            if (startSafely(i)) return "launcher:${pi.packageName}"
        }
        openAppInfo(packageName)
        return ""
    }

    /**
     * 打开信号源切换界面。
     *
     * 安卓没有统一的"切信号源"API —— 那是电视整机厂商的功能，藏在自家的
     * TvSettings 里，而且只有电视/盒子有这玩意儿，手机上没有。
     * 顺序：标准 TIF action → 厂商 action → 按关键词全机找 Activity
     *      （类名/桌面名里带 source / 信号源 / HDMI 的那个）→ 退系统设置。
     *
     * 返回："input:xxx" 表示真的进了信号源界面；"settings" 表示只打开了设置；
     *      空字符串表示什么都没打开。
     */
    private fun openInputSource(): String {
        for (a in INPUT_ACTIONS) {
            if (startSafely(Intent(a))) return "input:$a"
        }
        val words = listOf(
            "tvsource", "tv_source", "inputsource", "input_source", "sourceactivity",
            "tvcapture", "hdmi", "信号源", "信源", "输入源",
        )
        for ((pkg, cls) in findByKeywords(words)) {
            if (launchComponent(pkg, cls)) return "input:kw:$pkg/$cls"
        }
        return if (openSystemSettings().isNotEmpty()) "settings" else ""
    }

    /** 系统里登记的信号源列表（电视机型才有，手机是空的） */
    private fun listTvInputs(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < 21) return emptyList()
        val tm = try {
            getSystemService(Context.TV_INPUT_SERVICE) as? TvInputManager
        } catch (t: Throwable) {
            null
        } ?: return emptyList()

        val out = ArrayList<Map<String, Any?>>()
        val list = try {
            tm.tvInputList
        } catch (t: Throwable) {
            emptyList<TvInputInfo>()
        }
        for (info in list) {
            val label = try {
                info.loadLabel(this@MainActivity).toString()
            } catch (t: Throwable) {
                info.id
            }
            out.add(mapOf("id" to info.id, "label" to label))
        }
        return out
    }

    /** 桌面（Launcher）包名：清后台时不能把桌面干掉，否则电视直接黑屏 */
    private fun launcherPackages(): Set<String> {
        val s = HashSet<String>()
        try {
            val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            for (ri in packageManager.queryIntentActivities(i, 0)) {
                s.add(ri.activityInfo.packageName)
            }
        } catch (_: Throwable) {
        }
        return s
    }

    /**
     * 正在后台跑的第三方应用。
     *
     * 数据源只有 ActivityManager.runningAppProcesses —— 安卓 5.1 以后这个接口
     * 对普通应用只返回自己，读不到别人。所以这里返回的列表在老盒子（5.0）上
     * 是完整的，在新系统上可能就是空的，界面要据此显示一句人话解释。
     */
    private fun listBackgroundApps(): List<Map<String, Any?>> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val launchers = launcherPackages()
        val procs = try {
            am.runningAppProcesses
        } catch (t: Throwable) {
            null
        } ?: emptyList()

        val seen = HashSet<String>()
        val out = ArrayList<Map<String, Any?>>()
        for (p in procs) {
            if (p.pkgList.isEmpty()) continue
            val pkg = p.pkgList[0]
            if (pkg == packageName) continue
            if (launchers.contains(pkg)) continue
            if (!seen.add(pkg)) continue
            val info = try {
                packageManager.getApplicationInfo(pkg, 0)
            } catch (t: Throwable) {
                null
            } ?: continue
            // 系统应用一律不碰
            if ((info.flags and ApplicationInfo.FLAG_SYSTEM) != 0) continue
            val label = try {
                packageManager.getApplicationLabel(info).toString()
            } catch (t: Throwable) {
                pkg
            }
            out.add(mapOf("package" to pkg, "label" to label, "pid" to p.pid))
        }
        out.sortBy { it["label"] as String }
        return out
    }

    /**
     * 清后台：对每个后台第三方应用调 killBackgroundProcesses。
     *
     * 这是安卓给普通应用的唯一合法手段（要 KILL_BACKGROUND_PROCESSES 权限，
     * 属于安装即授权的普通权限）。它杀不掉前台应用、也杀不掉系统应用，
     * 系统想重启谁我们管不了 —— 这就是不用 root 能达到的上限。
     */
    private fun cleanBackgroundApps(): Map<String, Any?> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi0 = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi0)

        var killed = 0
        for (t in listBackgroundApps()) {
            val pkg = t["package"] as? String ?: continue
            try {
                am.killBackgroundProcesses(pkg)
                killed++
            } catch (_: Throwable) {
            }
        }
        Runtime.getRuntime().gc()

        val mi1 = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi1)
        return mapOf(
            "killed" to killed,
            "before" to mi0.availMem,
            "after" to mi1.availMem,
        )
    }

    /** 把已安装应用的 APK 复制到本应用外部目录，返回文件路径 */
    private fun extractApk(pkg: String?): String {
        if (pkg.isNullOrEmpty()) return ""
        val info = packageManager.getApplicationInfo(pkg, 0)
        val src = File(info.sourceDir)
        if (!src.exists()) return ""

        val label = try {
            packageManager.getApplicationLabel(info).toString()
        } catch (t: Throwable) {
            pkg
        }
        val safe = label.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        val dir = File(getExternalFilesDir(null), "apk")
        if (!dir.exists()) dir.mkdirs()
        val out = File(dir, "$safe.apk")
        src.inputStream().use { input ->
            out.outputStream().use { output -> input.copyTo(output) }
        }
        return out.absolutePath
    }

    /** 把若干文件/目录压成一个 zip，返回写入的条目数（-1 = 失败） */
    private fun zipPaths(paths: List<String>, outPath: String): Int {
        if (paths.isEmpty() || outPath.isEmpty()) return -1
        val out = File(outPath)
        out.parentFile?.mkdirs()
        var count = 0
        try {
            ZipOutputStream(BufferedOutputStream(FileOutputStream(out))).use { zos ->
                for (p in paths) {
                    val f = File(p)
                    if (f.exists()) addToZip(f, zos, f.name) { count++ }
                }
            }
        } catch (t: Throwable) {
            return -1
        }
        return count
    }

    private fun addToZip(f: File, zos: ZipOutputStream, entry: String, onEntry: () -> Unit) {
        if (f.isDirectory) {
            val kids = f.listFiles()
            if (kids == null || kids.isEmpty()) {
                zos.putNextEntry(ZipEntry("$entry/"))
                zos.closeEntry()
                onEntry()
                return
            }
            for (k in kids) addToZip(k, zos, "$entry/${k.name}", onEntry)
            return
        }
        zos.putNextEntry(ZipEntry(entry))
        f.inputStream().use { it.copyTo(zos) }
        zos.closeEntry()
        onEntry()
    }

    /** 解压到指定目录，返回解出的文件数（-1 = 失败） */
    private fun unzipTo(zipPath: String, dirPath: String): Int {
        if (zipPath.isEmpty() || dirPath.isEmpty()) return -1
        val root = File(dirPath)
        if (!root.exists()) root.mkdirs()
        val rootPath = root.canonicalPath
        var n = 0
        try {
            ZipFile(zipPath).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val e = entries.nextElement()
                    val out = File(root, e.name)
                    // 防 zip 里的 ../../ 穿越到别的目录
                    if (!out.canonicalPath.startsWith(rootPath)) continue
                    if (e.isDirectory) {
                        out.mkdirs()
                        continue
                    }
                    out.parentFile?.mkdirs()
                    zip.getInputStream(e).use { input ->
                        FileOutputStream(out).use { output -> input.copyTo(output) }
                    }
                    n++
                }
            }
        } catch (t: Throwable) {
            return -1
        }
        return n
    }

    /** 存储根目录信息：文件管理器的起点 + 有没有"所有文件访问"权限 */
    private fun storageInfo(): Map<String, Any?> {
        val roots = ArrayList<String>()
        try {
            for (f in File("/storage").listFiles() ?: emptyArray<File>()) {
                if (f.isDirectory && !f.name.startsWith("self")) roots.add(f.absolutePath)
            }
        } catch (_: Throwable) {
        }
        return mapOf(
            "roots" to roots.sorted(),
            "emulated" to (Environment.getExternalStorageDirectory()?.absolutePath ?: ""),
            "appDir" to (getExternalFilesDir(null)?.absolutePath ?: ""),
            "allFiles" to canManageAllFiles(),
        )
    }

    private fun canManageAllFiles(): Boolean {
        if (Build.VERSION.SDK_INT < 30) return true
        return try {
            Environment.isExternalStorageManager()
        } catch (t: Throwable) {
            false
        }
    }

    /** 安卓 11+ 要用户手动开"所有文件访问"，这里直接把他送到那一页 */
    private fun requestAllFiles(): Boolean {
        if (Build.VERSION.SDK_INT < 30) return true
        return try {
            startActivity(
                Intent(
                    "android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION",
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (t: Throwable) {
            startSafely(Intent("android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION"))
        }
    }

    /**
     * 开机自启动的应用。
     *
     * 判定口径按可靠程度分三级（逐级补充，前面有结果就不再往后堆）：
     *   1. 注册了开机广播的接收器 —— 最准。注意开机广播不止 BOOT_COMPLETED
     *      一个，国产 ROM 普遍用 QUICKBOOT_POWERON，只查前者会漏掉一大半。
     *   2. 申请了 RECEIVE_BOOT_COMPLETED 权限的应用 —— 广播查不到时的兜底。
     *   3. 都不行就返回空，界面会明说只能走系统自带的自启动管理。
     */
    private val BOOT_ACTIONS = listOf(
        Intent.ACTION_BOOT_COMPLETED,
        "android.intent.action.QUICKBOOT_POWERON",
        "com.htc.intent.action.QUICKBOOT_POWERON",
        "android.intent.action.LOCKED_BOOT_COMPLETED",
    )

    private fun listBootApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, Any?>>()

        fun add(pkg: String) {
            if (pkg == packageName) return
            if (!seen.add(pkg)) return
            val info = try {
                pm.getApplicationInfo(pkg, 0)
            } catch (t: Throwable) {
                null
            } ?: return
            val label = try {
                pm.getApplicationLabel(info).toString()
            } catch (t: Throwable) {
                pkg
            }
            out.add(
                mapOf(
                    "package" to pkg,
                    "label" to label,
                    "enabled" to info.enabled,
                    "system" to ((info.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                )
            )
        }

        // 1) 广播接收器（含被禁用的组件，否则"已禁止"的反而消失）
        val flags = PackageManager.MATCH_DISABLED_COMPONENTS or
            PackageManager.GET_DISABLED_COMPONENTS
        for (act in BOOT_ACTIONS) {
            val ris = try {
                pm.queryBroadcastReceivers(Intent(act), flags)
            } catch (t: Throwable) {
                emptyList<ResolveInfo>()
            }
            for (ri in ris) {
                val ai = ri.activityInfo ?: continue
                add(ai.packageName)
            }
        }

        // 2) 兜底：申请了 RECEIVE_BOOT_COMPLETED 的应用
        if (out.isEmpty()) {
            val pkgs = try {
                pm.getInstalledPackages(PackageManager.GET_PERMISSIONS)
            } catch (t: Throwable) {
                emptyList()
            }
            for (pi in pkgs) {
                val perms = pi.requestedPermissions ?: continue
                if (perms.contains("android.permission.RECEIVE_BOOT_COMPLETED")) {
                    add(pi.packageName)
                }
            }
        }

        out.sortWith(compareBy({ it["system"] as Boolean }, { it["label"] as String }))
        return out
    }

    /**
     * 禁止 / 恢复一个应用的自启动。
     *
     * 本质是把整个应用 disable 掉 —— 普通应用没有权限改别人的组件状态，
     * 只有 root 或系统签名能做到。所以先试 su，不行再试裸 pm，
     * 两者都失败就如实返回失败原因，让界面告诉用户"要 root 或去系统页面"。
     */
    private fun setBootEnabled(pkg: String, enable: Boolean): Map<String, Any?> {
        if (pkg.isEmpty()) return mapOf("ok" to false, "msg" to "包名为空")
        val cmd = if (enable) "pm enable \"$pkg\"" else "pm disable-user --user 0 \"$pkg\""

        var out = execShell("su -c '$cmd'")
        var ok = isEnabled(pkg) == enable
        if (!ok) {
            val out2 = execShell(cmd)
            ok = isEnabled(pkg) == enable
            out = if (out2.isNotEmpty()) out2 else out
        }
        return mapOf("ok" to ok, "msg" to out)
    }

    private fun isEnabled(pkg: String): Boolean = try {
        packageManager.getApplicationInfo(pkg, 0).enabled
    } catch (t: Throwable) {
        true
    }

    private fun execShell(cmd: String): String = try {
        val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", cmd))
        val text = p.inputStream.bufferedReader().use { it.readText() } +
                p.errorStream.bufferedReader().use { it.readText() }
        p.waitFor()
        text.trim()
    } catch (t: Throwable) {
        t.message ?: "执行失败"
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
