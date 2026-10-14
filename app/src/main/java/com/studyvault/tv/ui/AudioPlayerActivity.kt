package com.studyvault.tv.ui

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.SeekBar
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.studyvault.tv.R
import com.studyvault.tv.data.AccountStore
import com.studyvault.tv.data.RemoteFile
import com.studyvault.tv.data.SourceFactory
import com.studyvault.tv.data.ThumbnailManager
import com.studyvault.tv.databinding.ActivityAudioPlayerBinding
import com.studyvault.tv.util.Fmt
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** P6 音频播放页 */
class AudioPlayerActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_URIS = "uris"
        const val EXTRA_TITLES = "titles"
        const val EXTRA_PATHS = "paths"
        const val EXTRA_INDEX = "index"
    }

    private lateinit var binding: ActivityAudioPlayerBinding
    private var player: ExoPlayer? = null

    private var uris: List<String> = emptyList()
    private var titles: List<String> = emptyList()
    private var paths: List<String> = emptyList()
    private var index = 0
    private var dragging = false
    private var coverJob: Job? = null

    private val handler = Handler(Looper.getMainLooper())
    private val ticker = object : Runnable {
        override fun run() {
            updateProgress()
            handler.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityAudioPlayerBinding.inflate(layoutInflater)
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

        val exo = ExoPlayer.Builder(this).build()
        player = exo

        val account = AccountStore.current()
        val source = account?.let { SourceFactory.get(it) }
        val factory: DataSource.Factory? = source?.dataSourceFactory()
        if (factory != null) {
            exo.setMediaSourceFactory(DefaultMediaSourceFactory(factory))
        }

        exo.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                binding.btnPlay.setImageResource(
                    if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
                )
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                index = exo.currentMediaItemIndex
                updateTexts()
                loadCover()
            }

            override fun onPlayerError(error: PlaybackException) {
                Toast.makeText(
                    this@AudioPlayerActivity,
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
            }

            override fun onStopTrackingTouch(seekBar: SeekBar?) {
                dragging = false
                val p = player ?: return
                val duration = p.duration
                if (duration > 0) p.seekTo(duration * (seekBar?.progress ?: 0) / 1000)
            }
        })

        binding.btnPlay.setOnClickListener {
            val p = player ?: return@setOnClickListener
            if (p.isPlaying) p.pause() else p.play()
        }
        binding.btnPrev.setOnClickListener { player?.seekToPreviousMediaItem() }
        binding.btnNext.setOnClickListener { player?.seekToNextMediaItem() }

        exo.setMediaItems(uris.map { MediaItem.fromUri(it) }, index, 0L)
        exo.playWhenReady = true
        exo.prepare()

        updateTexts()
        loadCover()
        handler.post(ticker)
    }

    private fun updateTexts() {
        val name = titles.getOrNull(index) ?: uris.getOrNull(index) ?: ""
        binding.tvTitle.text = name
        binding.tvSong.text = name.substringBeforeLast('.')
        binding.tvAlbum.text = paths.getOrNull(index)?.substringBeforeLast('/') ?: "音频"
        binding.tvIndex.text = "${index + 1} / ${uris.size}"
    }

    private fun updateProgress() {
        val p = player ?: return
        val duration = p.duration
        val position = p.currentPosition
        if (duration > 0) {
            if (!dragging) {
                binding.seek.progress = ((position * 1000) / duration).toInt().coerceIn(0, 1000)
                binding.tvTime.text = Fmt.duration(position) + " / " + Fmt.duration(duration)
            }
        } else {
            binding.tvTime.text = Fmt.duration(position)
        }
    }

    private fun loadCover() {
        binding.cover.setImageResource(R.drawable.ic_placeholder)
        val account = AccountStore.current() ?: return
        val source = SourceFactory.get(account)
        val file = RemoteFile(
            name = titles.getOrNull(index) ?: "",
            path = paths.getOrNull(index) ?: "",
            isDirectory = false,
            size = 0L,
            lastModified = 0L,
            uri = uris.getOrNull(index) ?: ""
        )
        coverJob?.cancel()
        coverJob = lifecycleScope.launch {
            val bitmap = try {
                ThumbnailManager.load(this@AudioPlayerActivity, source, file)
            } catch (e: Throwable) {
                null
            }
            if (bitmap != null) binding.cover.setImageBitmap(bitmap)
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            val p = player
            if (p != null) {
                when (event.keyCode) {
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                    KeyEvent.KEYCODE_MEDIA_PLAY,
                    KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                        if (p.isPlaying) p.pause() else p.play()
                        return true
                    }
                    KeyEvent.KEYCODE_MEDIA_NEXT -> {
                        p.seekToNextMediaItem()
                        return true
                    }
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                        p.seekToPreviousMediaItem()
                        return true
                    }
                    else -> {
                        // 其它按键走默认流程
                    }
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        super.onDestroy()
        handler.removeCallbacks(ticker)
        coverJob?.cancel()
        try {
            player?.release()
        } catch (e: Exception) {
            // ignore
        }
        player = null
    }
}
