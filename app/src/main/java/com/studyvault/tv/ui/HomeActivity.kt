package com.studyvault.tv.ui

import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.LinearLayoutManager
import com.studyvault.tv.R
import com.studyvault.tv.data.AccountStore
import com.studyvault.tv.data.CategoryClassifier
import com.studyvault.tv.data.MediaCategory
import com.studyvault.tv.data.Prefs
import com.studyvault.tv.data.RemoteFile
import com.studyvault.tv.data.RemoteSource
import com.studyvault.tv.data.ServerAccount
import com.studyvault.tv.data.SourceFactory
import com.studyvault.tv.data.ThumbnailManager
import com.studyvault.tv.databinding.ActivityHomeBinding
import com.studyvault.tv.util.Fmt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class ListOutcome(
    val ok: Boolean,
    val files: List<RemoteFile>,
    val error: String?
)

/**
 * P3 主界面：左侧分类导航 + 右侧内容区，顶部一键切换账号。
 */
class HomeActivity : AppCompatActivity() {

    private lateinit var binding: ActivityHomeBinding
    private lateinit var fileAdapter: FileAdapter
    private lateinit var navAdapter: NavAdapter

    private var account: ServerAccount? = null
    private val pathStack = ArrayList<Pair<String, String>>()
    private var currentCategory: MediaCategory = MediaCategory.ALL
    private var currentFiles: List<RemoteFile> = emptyList()
    private var lastColumns = -1
    private var loading = false

    private fun src(): RemoteSource? = account?.let { SourceFactory.get(it) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityHomeBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val current = AccountStore.current() ?: AccountStore.all().firstOrNull()
        if (current == null) {
            Toast.makeText(this, "还没有服务器，请先添加一个", Toast.LENGTH_SHORT).show()
            startActivity(Intent(this, ServerListActivity::class.java))
            finish()
            return
        }
        account = current
        AccountStore.setCurrent(current.id)

        binding.tvServer.text = current.name
        binding.tvProtocol.text = current.type.label

        setupNav()
        setupContent()
        binding.btnSwitch.setOnClickListener { showAccountPicker() }

        // 启动时若还没设置过当前账号，默认从「全部文件」开始
        navAdapter.selectedPosition = INDEX_ALL
        currentCategory = MediaCategory.ALL

        val root = current.normalizedRoot()
        pathStack.clear()
        pathStack.add(root to current.name)
        loadPath(root)
    }

    private fun setupNav() {
        val items = listOf(
            NavItem(getString(R.string.cat_image), MediaCategory.IMAGE),
            NavItem(getString(R.string.cat_video), MediaCategory.VIDEO),
            NavItem(getString(R.string.cat_audio), MediaCategory.AUDIO),
            NavItem(getString(R.string.cat_movie), MediaCategory.MOVIE),
            NavItem(getString(R.string.cat_tvshow), MediaCategory.TVSHOW),
            NavItem(getString(R.string.cat_all), MediaCategory.ALL),
            NavItem(getString(R.string.cat_settings), null, isSettings = true)
        )
        val onPick: (NavItem) -> Unit = { item ->
            if (item.isSettings) {
                startActivity(Intent(this, SettingsActivity::class.java))
            } else {
                val cat = item.category
                if (cat != null) {
                    navAdapter.selectedPosition = items.indexOf(item)
                    currentCategory = cat
                    openCategory(cat)
                }
            }
        }
        navAdapter = NavAdapter(items, onPick)
        binding.navRecycler.layoutManager = LinearLayoutManager(this)
        binding.navRecycler.adapter = navAdapter
    }

    private fun setupContent() {
        fileAdapter = FileAdapter(
            scope = lifecycleScope,
            onClick = { file -> onItemClick(file) },
            onMenu = { file -> showFileInfo(file) },
            thumbLoader = { file -> loadThumb(file) }
        )
        applyGridColumns()
        binding.contentRecycler.adapter = fileAdapter
    }

    private fun applyGridColumns() {
        val columns = Prefs.columns.coerceIn(2, 8)
        val lm = binding.contentRecycler.layoutManager
        if (lm !is GridLayoutManager) {
            binding.contentRecycler.layoutManager = GridLayoutManager(this, columns)
            lastColumns = columns
        } else if (lastColumns != columns) {
            lm.spanCount = columns
            lastColumns = columns
        }
    }

    override fun onResume() {
        super.onResume()
        if (account != null) applyGridColumns()
    }

    // ---------------- 分类 ----------------

    private fun openCategory(cat: MediaCategory) {
        val acc = account ?: return
        val root = acc.normalizedRoot()

        if (cat == MediaCategory.ALL) {
            pathStack.clear()
            pathStack.add(root to acc.name)
            loadPath(root)
            return
        }

        showLoading(true)
        lifecycleScope.launch {
            val found = withContext(Dispatchers.IO) {
                try {
                    val children = src()?.list(root) ?: emptyList()
                    children.firstOrNull {
                        it.isDirectory && CategoryClassifier.classifyFolderName(it.name) == cat
                    }
                } catch (e: Throwable) {
                    null
                }
            }
            showLoading(false)
            if (found == null) {
                pathStack.clear()
                pathStack.add(root to acc.name)
                currentFiles = emptyList()
                fileAdapter.submit(emptyList())
                binding.tvCrumb.text = "${acc.name} / ${cat.label}（未找到）"
                showEmpty(getString(R.string.hint_category_missing))
            } else {
                pathStack.clear()
                pathStack.add(root to acc.name)
                pathStack.add(found.path to found.name)
                loadPath(found.path)
            }
        }
    }

    // ---------------- 目录加载 ----------------

    private fun loadPath(path: String) {
        val acc = account ?: return
        if (loading) return
        loading = true
        showLoading(true)
        binding.tvEmpty.visibility = View.GONE

        lifecycleScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                try {
                    ListOutcome(true, src()?.list(path) ?: emptyList(), null)
                } catch (e: Throwable) {
                    ListOutcome(false, emptyList(), e.message ?: e.javaClass.simpleName)
                }
            }
            loading = false
            showLoading(false)

            if (outcome.ok) {
                currentFiles = applySort(outcome.files)
                fileAdapter.submit(currentFiles)
                updateCrumb()
                updateSortLabel()
                if (currentFiles.isEmpty()) {
                    showEmpty(getString(R.string.hint_empty_dir))
                } else {
                    binding.tvEmpty.visibility = View.GONE
                    binding.contentRecycler.requestFocus()
                }
            } else {
                currentFiles = emptyList()
                fileAdapter.submit(emptyList())
                updateCrumb()
                showEmpty("读取失败：${outcome.error}")
            }
        }
    }

    private fun applySort(list: List<RemoteFile>): List<RemoteFile> {
        val dirs = list.filter { it.isDirectory }.sortedBy { it.name.lowercase() }
        val files = list.filter { !it.isDirectory }
        val comparator: Comparator<RemoteFile> = when (Prefs.sortBy) {
            Prefs.SORT_DATE -> compareBy<RemoteFile> { it.lastModified }
            Prefs.SORT_SIZE -> compareBy<RemoteFile> { it.size }
            else -> compareBy<RemoteFile> { it.name.lowercase() }
        }
        val ordered = if (Prefs.ascending) {
            files.sortedWith(comparator)
        } else {
            files.sortedWith(comparator.reversed())
        }
        return dirs + ordered
    }

    private fun showLoading(show: Boolean) {
        binding.progress.visibility = if (show) View.VISIBLE else View.GONE
    }

    private fun showEmpty(message: String) {
        binding.tvEmpty.text = message
        binding.tvEmpty.visibility = View.VISIBLE
    }

    private fun updateCrumb() {
        binding.tvCrumb.text = pathStack.joinToString(" / ") { it.second }
    }

    private fun updateSortLabel() {
        val name = when (Prefs.sortBy) {
            Prefs.SORT_DATE -> "时间"
            Prefs.SORT_SIZE -> "大小"
            else -> "名称"
        }
        binding.tvSort.text = if (Prefs.ascending) "$name ↑" else "$name ↓"
    }

    // ---------------- 点击行为 ----------------

    private fun onItemClick(file: RemoteFile) {
        if (file.isDirectory) {
            pathStack.add(file.path to file.name)
            loadPath(file.path)
            return
        }
        when {
            file.isImage -> openImages(file)
            file.isVideo -> openVideos(file)
            file.isAudio -> openAudios(file)
            else -> Toast.makeText(this, "这个格式暂时打不开", Toast.LENGTH_SHORT).show()
        }
    }

    private fun openVideos(file: RemoteFile) {
        val videos = currentFiles.filter { !it.isDirectory && it.isVideo }
        if (videos.isEmpty()) return
        val index = videos.indexOfFirst { it.path == file.path }.coerceAtLeast(0)
        val intent = Intent(this, PlayerActivity::class.java)
        intent.putStringArrayListExtra(PlayerActivity.EXTRA_URIS, ArrayList(videos.map { it.uri }))
        intent.putStringArrayListExtra(PlayerActivity.EXTRA_TITLES, ArrayList(videos.map { it.name }))
        intent.putExtra(PlayerActivity.EXTRA_INDEX, index)
        startActivity(intent)
    }

    private fun openImages(file: RemoteFile) {
        val images = currentFiles.filter { !it.isDirectory && it.isImage }
        if (images.isEmpty()) return
        val index = images.indexOfFirst { it.path == file.path }.coerceAtLeast(0)
        val intent = Intent(this, ImageViewerActivity::class.java)
        intent.putStringArrayListExtra(ImageViewerActivity.EXTRA_URIS, ArrayList(images.map { it.uri }))
        intent.putStringArrayListExtra(ImageViewerActivity.EXTRA_TITLES, ArrayList(images.map { it.name }))
        intent.putStringArrayListExtra(ImageViewerActivity.EXTRA_PATHS, ArrayList(images.map { it.path }))
        intent.putExtra(ImageViewerActivity.EXTRA_INDEX, index)
        startActivity(intent)
    }

    private fun openAudios(file: RemoteFile) {
        val audios = currentFiles.filter { !it.isDirectory && it.isAudio }
        if (audios.isEmpty()) return
        val index = audios.indexOfFirst { it.path == file.path }.coerceAtLeast(0)
        val intent = Intent(this, AudioPlayerActivity::class.java)
        intent.putStringArrayListExtra(AudioPlayerActivity.EXTRA_URIS, ArrayList(audios.map { it.uri }))
        intent.putStringArrayListExtra(AudioPlayerActivity.EXTRA_TITLES, ArrayList(audios.map { it.name }))
        intent.putStringArrayListExtra(AudioPlayerActivity.EXTRA_PATHS, ArrayList(audios.map { it.path }))
        intent.putExtra(AudioPlayerActivity.EXTRA_INDEX, index)
        startActivity(intent)
    }

    private suspend fun loadThumb(file: RemoteFile): Bitmap? {
        val s = src() ?: return null
        return ThumbnailManager.load(this, s, file)
    }

    // ---------------- 账号切换 ----------------

    private fun showAccountPicker() {
        val list = AccountStore.all()
        if (list.isEmpty()) {
            Toast.makeText(this, "还没有其它账号", Toast.LENGTH_SHORT).show()
            return
        }
        val names = list.map { "${it.name}（${it.type.label}）" }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.btn_switch_account))
            .setItems(names) { _, which ->
                val picked = list[which]
                AccountStore.setCurrent(picked.id)
                SourceFactory.invalidate()
                account = picked
                binding.tvServer.text = picked.name
                binding.tvProtocol.text = picked.type.label
                currentCategory = MediaCategory.ALL
                navAdapter.selectedPosition = INDEX_ALL
                val root = picked.normalizedRoot()
                pathStack.clear()
                pathStack.add(root to picked.name)
                loadPath(root)
            }
            .setNegativeButton("取消", null)
            .show()
    }

    // ---------------- 遥控器 ----------------

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_MENU) {
            showSortDialog()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (pathStack.size > 1) {
            pathStack.removeAt(pathStack.size - 1)
            loadPath(pathStack.last().first)
        } else {
            super.onBackPressed()
        }
    }

    private fun showSortDialog() {
        val options = arrayOf(
            "名称 升序", "名称 降序",
            "时间 升序", "时间 降序",
            "大小 升序", "大小 降序"
        )
        AlertDialog.Builder(this)
            .setTitle("排序方式")
            .setItems(options) { _, which ->
                when (which) {
                    0 -> { Prefs.sortBy = Prefs.SORT_NAME; Prefs.ascending = true }
                    1 -> { Prefs.sortBy = Prefs.SORT_NAME; Prefs.ascending = false }
                    2 -> { Prefs.sortBy = Prefs.SORT_DATE; Prefs.ascending = true }
                    3 -> { Prefs.sortBy = Prefs.SORT_DATE; Prefs.ascending = false }
                    4 -> { Prefs.sortBy = Prefs.SORT_SIZE; Prefs.ascending = true }
                    5 -> { Prefs.sortBy = Prefs.SORT_SIZE; Prefs.ascending = false }
                }
                currentFiles = applySort(currentFiles)
                fileAdapter.submit(currentFiles)
                updateSortLabel()
            }
            .show()
    }

    private fun showFileInfo(file: RemoteFile) {
        val info = buildString {
            append(file.name).append('\n').append('\n')
            append("类型：").append(if (file.isDirectory) "文件夹" else file.ext.uppercase()).append('\n')
            if (!file.isDirectory) {
                append("大小：").append(Fmt.size(file.size)).append('\n')
            }
            if (file.lastModified > 0) {
                append("修改时间：").append(Fmt.date(file.lastModified)).append('\n')
            }
            append("路径：").append(file.path)
        }
        AlertDialog.Builder(this)
            .setTitle("文件信息")
            .setMessage(info)
            .setPositiveButton("知道了", null)
            .setNeutralButton("打开") { _, _ -> onItemClick(file) }
            .show()
    }

    companion object {
        private const val INDEX_ALL = 5
    }
}
