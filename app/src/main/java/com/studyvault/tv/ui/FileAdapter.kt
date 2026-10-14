package com.studyvault.tv.ui

import android.graphics.Bitmap
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import com.studyvault.tv.R
import com.studyvault.tv.data.Prefs
import com.studyvault.tv.data.RemoteFile
import com.studyvault.tv.data.ThumbnailManager
import com.studyvault.tv.databinding.ItemFileBinding
import com.studyvault.tv.util.Fmt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class FileAdapter(
    private val scope: CoroutineScope,
    private val onClick: (RemoteFile) -> Unit,
    private val onMenu: ((RemoteFile) -> Unit)? = null,
    private val thumbLoader: (suspend (RemoteFile) -> Bitmap?)? = null
) : RecyclerView.Adapter<FileAdapter.VH>() {

    private val items = ArrayList<RemoteFile>()

    fun submit(list: List<RemoteFile>) {
        items.clear()
        items.addAll(list)
        notifyDataSetChanged()
    }

    fun itemAt(position: Int): RemoteFile? = items.getOrNull(position)

    class VH(val binding: ItemFileBinding) : RecyclerView.ViewHolder(binding.root) {
        var thumbJob: Job? = null
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH =
        VH(ItemFileBinding.inflate(LayoutInflater.from(parent.context), parent, false))

    override fun getItemCount(): Int = items.size

    override fun onViewRecycled(holder: VH) {
        super.onViewRecycled(holder)
        holder.thumbJob?.cancel()
        holder.thumbJob = null
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        val file = items[position]
        val b = holder.binding

        b.tvName.text = file.name
        b.tvMeta.text = buildMeta(file)
        b.root.setOnClickListener { onClick(file) }
        b.root.setOnLongClickListener {
            onMenu?.invoke(file)
            true
        }
        bindThumb(holder, file)
    }

    private fun bindThumb(holder: VH, file: RemoteFile) {
        val b = holder.binding
        holder.thumbJob?.cancel()
        holder.thumbJob = null

        if (!Prefs.thumbnails) {
            b.thumb.setImageResource(R.drawable.ic_placeholder)
            return
        }

        val key = ThumbnailManager.cacheKey(file.uri, file.size, file.lastModified)
        val cached = ThumbnailManager.peek(key)
        if (cached != null) {
            b.thumb.setImageBitmap(cached)
            return
        }

        b.thumb.setImageResource(R.drawable.ic_placeholder)
        val loader = thumbLoader ?: return
        holder.thumbJob = scope.launch {
            val bitmap = try {
                loader(file)
            } catch (e: Throwable) {
                null
            }
            if (bitmap == null) return@launch
            val pos = holder.bindingAdapterPosition
            if (pos == RecyclerView.NO_POSITION) return@launch
            if (items.getOrNull(pos)?.uri != file.uri) return@launch
            holder.binding.thumb.setImageBitmap(bitmap)
        }
    }

    private fun buildMeta(file: RemoteFile): String {
        if (file.isDirectory) return "文件夹"
        val parts = ArrayList<String>(2)
        if (file.size > 0) parts.add(Fmt.size(file.size))
        if (file.lastModified > 0) {
            val text = Fmt.date(file.lastModified)
            parts.add(text.substringBefore(' '))
        }
        return if (parts.isEmpty()) file.ext.uppercase() else parts.joinToString(" · ")
    }
}
