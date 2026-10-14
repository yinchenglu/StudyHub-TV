package com.studyvault.tv.ui

import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.SeekBar
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.studyvault.tv.R
import com.studyvault.tv.data.AccountStore
import com.studyvault.tv.data.SourceFactory
import com.studyvault.tv.databinding.ActivityPlayerBinding
import com.studyvault.tv.util.Fmt
import android.os.Handler
import android.os.Looper

/**
 * P4 视频播放页。播放内核 Media3 / ExoPlayer。
 * 遥控器：OK 播放暂停 · 左右快退快进 10 秒 · 上下调音量 · 返回退出
 */
class PlayerActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_URIS = "uris"
        const val EXTRA_TITLES = "titles"
        const val EXTRA_INDEX = "index"
        private const val HIDE_DELAY = 4000L
        private const val SEEK_STEP = 10_000L
    }

    private lateinit var binding: ActivityPlayerBinding
    private var player: ExoPlayer? = null

    private var uris: List<String> = emptyList()
    private var titles: List<String> = emptyList()

    private var dragging = false
    private var volume = 1f
    private var controlsVisible = true

    private val handler = Handler(Looper.getMainLooper())
    private val hideRunnable = Runnable { hideControls() }
    private val ticker = object : Runnable {
        override fun run() {
            updateProgress()
            handler.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityPlayerBinding.inflate(layoutInflater)
        setContentView(binding.root)

        uris = intent.getStringArrayListExtra(EXTRA_URIS).orEmpty()
        titles = intent.getStringArrayListExtra(EXTRA_TITLES).orEmpty()
        val startIndex = intent.getIntExtra(EXTRA_INDEX, 0)

        if (uris.isEmpty()) {
            finish()
            return
        }

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // SMB 走自定义数据源；WebDAV 走带认证头的 HTTP 数据源
        val account = AccountStore.current()
        val source = account?.let { SourceFactory.get(it) }
        val dataSourceFactory: DataSource.Factory? = source?.dataSourceFactory()

        // 注意：setMediaSourceFactory 只声明在 ExoPlayer.Builder 上，
        // ExoPlayer 接口没有这个方法，所以必须在 build() 之前设置。
        val builder = ExoPlayer.Builder(this)
        if (dataSourceFactory != null) {
            builder.setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
        }
        val exo = builder.build()
        player = exo
        binding.playerView.player = exo

        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                binding.progress.visibility =
                    if (playbackState == Player.STATE_BUFFERING) View.VISIBLE else View.GONE
                if (playbackState == Player.STATE_READY) updateProgress()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                binding.btnPlay.setImageResource(
                    if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
                )
                if (isPlaying) scheduleHide()
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                updateTitle()
            }

            override fun onPlayerError(error: PlaybackException) {
                Toast.makeText(
                    this@PlayerActivity,
                    "播放失败：" + (error.message ?: error.errorCodeName),
                    Toast.LENGTH_LONG
                ).show()
            }
        })

        binding.seek.max = 1000
        binding.seek.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                if (!fromUser) return
                val p = player ?: return
                val duration = p.duration
                if (duration > 0) {
                    binding.tvTime.text = Fmt.duration(duration * progress / 1000) +
                        " / " + Fmt.duration(duration)
                }
            }

            override fun onStartTrackingTouch(seekBar: SeekBar?) {
                dragging = true
                cancelHide()
            }

            override fun onStopTrackingTouch(seekBar: SeekBar?) {
                dragging = false
                val p = player ?: return
                val duration = p.duration
                if (duration > 0) {
                    p.seekTo(duration * (seekBar?.progress ?: 0) / 1000)
                }
                scheduleHide()
            }
        })

        binding.btnPlay.setOnClickListener { togglePlay() }
        binding.btnPrev.setOnClickListener { player?.seekToPreviousMediaItem() }
        binding.btnNext.setOnClickListener { player?.seekToNextMediaItem() }

        exo.setMediaItems(
            uris.map { MediaItem.fromUri(it) },
            startIndex.coerceIn(0, (uris.size - 1).coerceAtLeast(0)),
            0L
        )
        exo.playWhenReady = true
        exo.prepare()

        updateTitle()
        showControls()
        handler.post(ticker)
    }

    private fun togglePlay() {
        val p = player ?: return
        if (p.isPlaying) p.pause() else p.play()
        showControls()
    }

    private fun updateTitle() {
        val p = player ?: return
        val idx = p.currentMediaItemIndex
        binding.tvTitle.text = titles.getOrNull(idx) ?: uris.getOrNull(idx) ?: ""
        binding.tvIndex.text = "${idx + 1} / ${uris.size}"
    }

    private fun updateProgress() {
        val p = player ?: return
        val duration = p.duration
        val position = p.currentPosition
        if (duration > 0) {
            if (!dragging) {
                binding.seek.progress = ((position * 1000) / duration).toInt().coerceIn(0, 1000)
                binding.tvTime.text =
                    Fmt.duration(position) + " / " + Fmt.duration(duration)
            }
        } else {
            binding.tvTime.text = Fmt.duration(position)
        }
    }

    private fun showControls() {
        controlsVisible = true
        binding.controls.visibility = View.VISIBLE
        binding.tvTitle.visibility = View.VISIBLE
        scheduleHide()
    }

    private fun hideControls() {
        if (binding.controls.hasFocus()) {
            scheduleHide()
            return
        }
        controlsVisible = false
        binding.controls.visibility = View.GONE
        binding.tvTitle.visibility = View.GONE
    }

    private fun scheduleHide() {
        handler.removeCallbacks(hideRunnable)
        handler.postDelayed(hideRunnable, HIDE_DELAY)
    }

    private fun cancelHide() {
        handler.removeCallbacks(hideRunnable)
    }

    private fun changeVolume(delta: Float) {
        volume = (volume + delta).coerceIn(0f, 1f)
        player?.volume = volume
        Toast.makeText(this, "音量 ${(volume * 100).toInt()}%", Toast.LENGTH_SHORT).show()
        showControls()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            val p = player
            if (p != null) {
                when (event.keyCode) {
                    KeyEvent.KEYCODE_DPAD_LEFT -> {
                        p.seekTo((p.currentPosition - SEEK_STEP).coerceAtLeast(0L))
                        showControls()
                        return true
                    }
                    KeyEvent.KEYCODE_DPAD_RIGHT -> {
                        p.seekTo(p.currentPosition + SEEK_STEP)
                        showControls()
                        return true
                    }
                    KeyEvent.KEYCODE_DPAD_UP -> {
                        changeVolume(0.05f)
                        return true
                    }
                    KeyEvent.KEYCODE_DPAD_DOWN -> {
                        changeVolume(-0.05f)
                        return true
                    }
                    KeyEvent.KEYCODE_DPAD_CENTER,
                    KeyEvent.KEYCODE_ENTER,
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                    KeyEvent.KEYCODE_MEDIA_PLAY,
                    KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                        togglePlay()
                        return true
                    }
                    KeyEvent.KEYCODE_MEDIA_NEXT -> {
                        p.seekToNextMediaItem()
                        showControls()
                        return true
                    }
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                        p.seekToPreviousMediaItem()
                        showControls()
                        return true
                    }
                    else -> {
                        // 其它按键继续走默认流程
                    }
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onPause() {
        super.onPause()
        player?.pause()
    }

    override fun onDestroy() {
        super.onDestroy()
        handler.removeCallbacks(ticker)
        handler.removeCallbacks(hideRunnable)
        try {
            binding.playerView.player = null
            player?.release()
        } catch (e: Exception) {
            // ignore
        }
        player = null
    }
}
