package com.studyvault.tv.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.studyvault.tv.data.AccountStore
import com.studyvault.tv.data.Prefs
import com.studyvault.tv.data.SourceFactory
import com.studyvault.tv.data.ThumbnailManager
import com.studyvault.tv.databinding.ActivitySettingsBinding
import com.studyvault.tv.databinding.ItemSettingBinding
import com.studyvault.tv.util.Fmt

/** P7 设置页 */
class SettingsActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySettingsBinding
    private lateinit var adapter: SettingAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        adapter = SettingAdapter { row -> row.action() }
        binding.recycler.layoutManager = LinearLayoutManager(this)
        binding.recycler.adapter = adapter
        rebuild()
    }

    override fun onResume() {
        super.onResume()
        rebuild()
    }

    private fun rebuild() {
        val rows = ArrayList<SettingRow>()

        rows.add(
            SettingRow("网格每行列数", "${Prefs.columns}") {
                pickColumns()
            }
        )
        rows.add(
            SettingRow("排序方式", sortLabel()) {
                pickSort()
            }
        )
        rows.add(
            SettingRow("生成预览图", if (Prefs.thumbnails) "已开启" else "已关闭") {
                Prefs.thumbnails = !Prefs.thumbnails
                rebuild()
            }
        )
        rows.add(
            SettingRow("预览图缓存", Fmt.size(ThumbnailManager.cacheSizeBytes(this))) {
                AlertDialog.Builder(this)
                    .setTitle("清空预览图缓存")
                    .setMessage("清掉之后重新浏览会重新生成，不会影响服务器上的文件。")
                    .setPositiveButton("清空") { _, _ ->
                        ThumbnailManager.clear(this)
                        rebuild()
                    }
                    .setNegativeButton("取消", null)
                    .show()
            }
        )
        val accountName = AccountStore.current()?.name ?: "未选择"
        rows.add(
            SettingRow("当前账号", accountName) {
                SourceFactory.invalidate()
                rebuild()
            }
        )
        rows.add(
            SettingRow("关于", "StudyHub-TV 1.0.0") {
                AlertDialog.Builder(this)
                    .setTitle("关于 StudyHub-TV")
                    .setMessage(
                        "StudyHub-TV 1.0.0\n\n" +
                            "一个跑在安卓电视上的媒体库浏览器，支持 SMB / WebDAV，\n" +
                            "自动识别图片、视频、音频、电影、电视剧文件夹。\n\n" +
                            "播放内核：AndroidX Media3 (ExoPlayer)\n" +
                            "SMB：jcifs-ng\n" +
                            "最低支持 Android 5.0"
                    )
                    .setPositiveButton("知道了", null)
                    .show()
            }
        )

        adapter.submit(rows)
    }

    private fun sortLabel(): String {
        val name = when (Prefs.sortBy) {
            Prefs.SORT_DATE -> "时间"
            Prefs.SORT_SIZE -> "大小"
            else -> "名称"
        }
        return if (Prefs.ascending) "$name ↑" else "$name ↓"
    }

    private fun pickColumns() {
        val options = arrayOf("3 列", "4 列", "5 列", "6 列")
        val values = intArrayOf(3, 4, 5, 6)
        val checked = values.indexOfFirst { it == Prefs.columns }.coerceAtLeast(0)
        AlertDialog.Builder(this)
            .setTitle("网格每行列数")
            .setSingleChoiceItems(options, checked) { dialog, which ->
                Prefs.columns = values[which]
                dialog.dismiss()
                rebuild()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun pickSort() {
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
                rebuild()
            }
            .show()
    }
}

private class SettingRow(val title: String, val value: String, val action: () -> Unit)

private class SettingAdapter(
    private val onClick: (SettingRow) -> Unit
) : RecyclerView.Adapter<SettingAdapter.VH>() {

    private val items = ArrayList<SettingRow>()

    fun submit(rows: List<SettingRow>) {
        items.clear()
        items.addAll(rows)
        notifyDataSetChanged()
    }

    class VH(val binding: ItemSettingBinding) : RecyclerView.ViewHolder(binding.root)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH =
        VH(ItemSettingBinding.inflate(LayoutInflater.from(parent.context), parent, false))

    override fun getItemCount(): Int = items.size

    override fun onBindViewHolder(holder: VH, position: Int) {
        val row = items[position]
        holder.binding.tvTitle.text = row.title
        holder.binding.tvValue.text = row.value
        holder.binding.root.setOnClickListener { onClick(row) }
    }
}
