package com.studyvault.tv.ui

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.RecyclerView
import com.studyvault.tv.R
import com.studyvault.tv.data.MediaCategory
import com.studyvault.tv.databinding.ItemCategoryBinding

/** 左侧导航项：分类 或 设置 */
data class NavItem(val label: String, val category: MediaCategory?, val isSettings: Boolean = false)

class NavAdapter(
    private val items: List<NavItem>,
    private val onPick: (NavItem) -> Unit
) : RecyclerView.Adapter<NavAdapter.VH>() {

    var selectedPosition: Int = 0
        set(value) {
            if (field == value) return
            val old = field
            field = value
            if (old in items.indices) notifyItemChanged(old)
            if (value in items.indices) notifyItemChanged(value)
        }

    class VH(val binding: ItemCategoryBinding) : RecyclerView.ViewHolder(binding.root)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH =
        VH(ItemCategoryBinding.inflate(LayoutInflater.from(parent.context), parent, false))

    override fun getItemCount(): Int = items.size

    override fun onBindViewHolder(holder: VH, position: Int) {
        val item = items[position]
        val tv = holder.binding.root
        val context = tv.context

        tv.text = item.label
        tv.isSelected = position == selectedPosition
        tv.setTextColor(
            ContextCompat.getColor(
                context,
                if (position == selectedPosition) R.color.accent else R.color.text_secondary
            )
        )
        tv.setOnClickListener { onPick(item) }
    }
}
