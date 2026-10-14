package com.studyvault.tv.ui

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import com.studyvault.tv.data.ServerAccount
import com.studyvault.tv.databinding.ItemServerBinding

class ServerAdapter(
    private val onOpen: (ServerAccount) -> Unit,
    private val onMenu: (ServerAccount) -> Unit
) : RecyclerView.Adapter<ServerAdapter.VH>() {

    private val items = ArrayList<ServerAccount>()

    fun submit(list: List<ServerAccount>) {
        items.clear()
        items.addAll(list)
        notifyDataSetChanged()
    }

    class VH(val binding: ItemServerBinding) : RecyclerView.ViewHolder(binding.root)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH =
        VH(ItemServerBinding.inflate(LayoutInflater.from(parent.context), parent, false))

    override fun getItemCount(): Int = items.size

    override fun onBindViewHolder(holder: VH, position: Int) {
        val account = items[position]
        val b = holder.binding
        b.tvName.text = account.name
        b.tvTag.text = account.type.label
        b.tvAddress.text = account.address
        b.root.setOnClickListener { onOpen(account) }
        b.root.setOnLongClickListener {
            onMenu(account)
            true
        }
    }
}
