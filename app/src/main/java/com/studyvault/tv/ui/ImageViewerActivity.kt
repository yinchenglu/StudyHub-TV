package com.studyvault.tv.ui

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.studyvault.tv.data.AccountStore
import com.studyvault.tv.data.RemoteFile
import com.studyvault.tv.data.SourceFactory
import com.studyvault.tv.data.ThumbnailManager
import com.studyvault.tv.databinding.ActivityImageViewerBinding
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** P5 图片查看页：左右切换、支持缩放、幻灯片播放 */
class ImageViewerActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_URIS = "uris"
        const val EXTRA_TITLES = "titles"
        const val EXTRA_PATHS = "paths"
        const val EXTRA_INDEX = "index"
        private const val SLIDE_INTERVAL = 5000L
    }

    private lateinit var binding: ActivityImageViewerBinding
    private var uris: List<String> = emptyList()
    private var titles: List<String> = emptyList()
    private var paths: List<String> = emptyList()
    private var index = 0
    private var loadJob: Job? = null
    private var sliding = false

    private val handler = Handler(Looper.getMainLooper())
    private val slideRunnable = object : Runnable {
        override fun run() {
            if (sliding) {
                next()
                handler.postDelayed(this, SLIDE_INTERVAL)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityImageViewerBinding.inflate(layoutInflater)
        setContentView(binding.root)

        uris = intent.getStringArrayListExtra(EXTRA_URIS).orEmpty()
        titles = intent.getStringArrayListExtra(EXTRA_TITLES).orEmpty()
        paths = intent.getStringArrayListExtra(EXTRA_PATHS).orEmpty()
        index = intent.getIntExtra(EXTRA_INDEX, 0)

        if (uris.isEmpty()) {
            finish()
            return
        }
        index = index.coerceIn(0, uris.size - 1)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        binding.btnPrev.setOnClickListener { prev() }
        binding.btnNext.setOnClickListener { next() }
        binding.btnSlide.setOnClickListener { toggleSlide() }

        show()
    }

    private fun show() {
        binding.tvTitle.text = titles.getOrNull(index) ?: ""
        binding.tvIndex.text = "${index + 1} / ${uris.size}"
        binding.image.resetZoom()
        binding.image.setImageDrawable(null)
        binding.progress.visibility = View.VISIBLE

        loadJob?.cancel()
        val account = AccountStore.current()
        if (account == null) {
            binding.progress.visibility = View.GONE
            return
        }
        val source = SourceFactory.get(account)
        val file = RemoteFile(
            name = titles.getOrNull(index) ?: "",
            path = paths.getOrNull(index) ?: "",
            isDirectory = false,
            size = 0L,
            lastModified = 0L,
            uri = uris.getOrNull(index) ?: ""
        )

        loadJob = lifecycleScope.launch {
            val bitmap = ThumbnailManager.loadFull(source, file, 1920, 1080)
            binding.progress.visibility = View.GONE
            if (bitmap != null) {
                binding.image.setImageBitmap(bitmap)
            } else {
                Toast.makeText(this@ImageViewerActivity, "这张图打不开", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun prev() {
        if (uris.isEmpty()) return
        index = (index - 1 + uris.size) % uris.size
        show()
    }

    private fun next() {
        if (uris.isEmpty()) return
        index = (index + 1) % uris.size
        show()
    }

    private fun toggleSlide() {
        sliding = !sliding
        binding.btnSlide.text = if (sliding) "停止幻灯" else "幻灯片"
        handler.removeCallbacks(slideRunnable)
        if (sliding) handler.postDelayed(slideRunnable, SLIDE_INTERVAL)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> {
                    prev()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_RIGHT -> {
                    next()
                    return true
                }
                KeyEvent.KEYCODE_MENU -> {
                    binding.image.zoomBy(1.5f)
                    Toast.makeText(this, "放大（再按菜单键继续放大）", Toast.LENGTH_SHORT).show()
                    return true
                }
                else -> {
                    // 其它按键走默认流程
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        super.onDestroy()
        handler.removeCallbacks(slideRunnable)
        loadJob?.cancel()
    }
}
