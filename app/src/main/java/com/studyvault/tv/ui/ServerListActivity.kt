package com.studyvault.tv.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import com.studyvault.tv.data.AccountStore
import com.studyvault.tv.data.ServerAccount
import com.studyvault.tv.data.SourceFactory
import com.studyvault.tv.databinding.ActivityServerListBinding

/**
 * P1 账号选择页。
 * 所有账号在这里一览无余，按 OK 就是「一键切换」并进入主界面。
 * 长按（或按住 OK）弹出编辑 / 删除菜单。
 */
class ServerListActivity : AppCompatActivity() {

    private lateinit var binding: ActivityServerListBinding
    private lateinit var adapter: ServerAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityServerListBinding.inflate(layoutInflater)
        setContentView(binding.root)

        adapter = ServerAdapter(
            onOpen = { account -> openHome(account) },
            onMenu = { account -> showItemMenu(account) }
        )
        binding.recycler.layoutManager = LinearLayoutManager(this)
        binding.recycler.adapter = adapter
        binding.btnAdd.setOnClickListener { openEdit(null) }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        val list = AccountStore.all()
        adapter.submit(list)
        val empty = list.isEmpty()
        binding.tvEmpty.visibility = if (empty) View.VISIBLE else View.GONE
        binding.recycler.visibility = if (empty) View.GONE else View.VISIBLE
        if (empty) {
            binding.btnAdd.requestFocus()
        }
    }

    private fun openHome(account: ServerAccount) {
        AccountStore.setCurrent(account.id)
        SourceFactory.invalidate()
        startActivity(Intent(this, HomeActivity::class.java))
    }

    private fun openEdit(account: ServerAccount?) {
        val intent = Intent(this, ServerEditActivity::class.java)
        if (account != null) intent.putExtra(ServerEditActivity.EXTRA_ID, account.id)
        startActivity(intent)
    }

    private fun showItemMenu(account: ServerAccount) {
        val options = arrayOf("编辑", "删除")
        AlertDialog.Builder(this)
            .setTitle(account.name)
            .setItems(options) { _, which ->
                when (which) {
                    0 -> openEdit(account)
                    1 -> confirmDelete(account)
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun confirmDelete(account: ServerAccount) {
        AlertDialog.Builder(this)
            .setTitle("删除服务器")
            .setMessage("确定删除「${account.name}」吗？只是移除这个账号，不会动服务器上的文件。")
            .setPositiveButton("删除") { _, _ ->
                AccountStore.delete(account.id)
                SourceFactory.invalidate()
                refresh()
            }
            .setNegativeButton("取消", null)
            .show()
    }
}
