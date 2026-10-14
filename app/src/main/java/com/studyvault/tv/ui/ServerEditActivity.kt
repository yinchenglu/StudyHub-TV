package com.studyvault.tv.ui

import android.os.Bundle
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.studyvault.tv.R
import com.studyvault.tv.data.AccountStore
import com.studyvault.tv.data.ProtocolType
import com.studyvault.tv.data.ServerAccount
import com.studyvault.tv.data.SmbSource
import com.studyvault.tv.data.SourceFactory
import com.studyvault.tv.data.WebDavSource
import com.studyvault.tv.databinding.ActivityServerEditBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** P2 添加 / 编辑服务器 */
class ServerEditActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_ID = "server_id"
    }

    private lateinit var binding: ActivityServerEditBinding
    private var editId: String? = null
    private var testing = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityServerEditBinding.inflate(layoutInflater)
        setContentView(binding.root)

        editId = intent.getStringExtra(EXTRA_ID)

        binding.rgProtocol.setOnCheckedChangeListener { _, checkedId ->
            val isSmb = checkedId == R.id.rbSmb
            binding.cbHttps.visibility = if (isSmb) View.GONE else View.VISIBLE
            val current = binding.etPort.text?.toString()?.trim().orEmpty()
            if (current.isEmpty() || current == "445" || current == "80" || current == "443") {
                binding.etPort.setText(if (isSmb) "445" else "80")
            }
            binding.etShare.visibility = if (isSmb) View.VISIBLE else View.GONE
        }

        val existing = editId?.let { AccountStore.get(it) }
        if (existing != null) {
            binding.tvTitle.text = getString(R.string.title_edit_server)
            fill(existing)
            binding.btnDelete.visibility = View.VISIBLE
        } else {
            binding.tvTitle.text = getString(R.string.title_add_server)
            binding.etPort.setText("445")
        }

        binding.btnSave.setOnClickListener { save() }
        binding.btnCancel.setOnClickListener { finish() }
        binding.btnTest.setOnClickListener { testConnection() }
        binding.btnDelete.setOnClickListener { confirmDelete() }
    }

    private fun fill(account: ServerAccount) {
        if (account.type == ProtocolType.WEBDAV) {
            binding.rbWebdav.isChecked = true
            binding.cbHttps.visibility = View.VISIBLE
            binding.etShare.visibility = View.GONE
        } else {
            binding.rbSmb.isChecked = true
        }
        binding.etName.setText(account.name)
        binding.etHost.setText(account.host)
        binding.etPort.setText(account.port.toString())
        binding.etShare.setText(account.share)
        binding.etRoot.setText(account.rootPath)
        binding.etUser.setText(account.username)
        binding.etPassword.setText(account.password)
        binding.cbHttps.isChecked = account.https
    }

    private fun sanitizeHost(raw: String): String {
        var host = raw.trim()
        host = host.removePrefix("smb://")
            .removePrefix("http://")
            .removePrefix("https://")
            .removePrefix("\\\\")
            .removePrefix("\\")
        host = host.trim()
        if (host.contains('/')) host = host.substringBefore('/')
        return host.trimEnd('/').trim()
    }

    private fun buildAccount(): ServerAccount? {
        val host = sanitizeHost(binding.etHost.text?.toString().orEmpty())
        if (host.isEmpty()) {
            toast("请先填写服务器地址")
            return null
        }
        val type = if (binding.rbWebdav.isChecked) ProtocolType.WEBDAV else ProtocolType.SMB
        val port = binding.etPort.text?.toString()?.trim()?.toIntOrNull() ?: type.defaultPort
        var root = binding.etRoot.text?.toString()?.trim().orEmpty()
        if (root.isEmpty()) root = "/"
        if (!root.startsWith("/")) root = "/$root"

        val name = binding.etName.text?.toString()?.trim().orEmpty()
        return ServerAccount(
            id = editId ?: AccountStore.newId(),
            name = if (name.isEmpty()) host else name,
            type = type,
            host = host,
            port = port,
            share = binding.etShare.text?.toString()?.trim()?.trim('/').orEmpty(),
            rootPath = root,
            username = binding.etUser.text?.toString()?.trim().orEmpty(),
            password = binding.etPassword.text?.toString().orEmpty(),
            https = type == ProtocolType.WEBDAV && binding.cbHttps.isChecked
        )
    }

    private fun save() {
        val account = buildAccount() ?: return
        if (account.type == ProtocolType.SMB && account.share.isEmpty()) {
            toast("SMB 需要填写共享名，例如 media")
            return
        }
        AccountStore.save(account)
        if (AccountStore.currentId() == null) {
            AccountStore.setCurrent(account.id)
        }
        SourceFactory.invalidate()
        toast("已保存")
        finish()
    }

    private fun testConnection() {
        val account = buildAccount() ?: return
        if (testing) return
        testing = true
        binding.btnTest.isEnabled = false
        binding.tvResult.setTextColor(ContextCompat.getColor(this, R.color.text_secondary))
        binding.tvResult.text = "正在连接…"

        lifecycleScope.launch {
            val message = withContext(Dispatchers.IO) {
                val source = when (account.type) {
                    ProtocolType.SMB -> SmbSource(account)
                    ProtocolType.WEBDAV -> WebDavSource(account)
                }
                try {
                    val files = source.list(account.normalizedRoot())
                    "连接成功，该目录下有 ${files.size} 项"
                } catch (e: Throwable) {
                    "连接失败：" + (e.message ?: e.javaClass.simpleName)
                } finally {
                    try {
                        source.close()
                    } catch (e: Exception) {
                        // ignore
                    }
                }
            }
            val ok = message.startsWith("连接成功")
            binding.tvResult.text = if (ok) "✔ $message" else "✘ $message"
            binding.tvResult.setTextColor(
                ContextCompat.getColor(
                    this@ServerEditActivity,
                    if (ok) R.color.ok else R.color.danger
                )
            )
            binding.btnTest.isEnabled = true
            testing = false
        }
    }

    private fun confirmDelete() {
        val id = editId ?: return
        val account = AccountStore.get(id) ?: return
        AlertDialog.Builder(this)
            .setTitle("删除服务器")
            .setMessage("确定删除「${account.name}」吗？只是移除这个账号，不会动服务器上的文件。")
            .setPositiveButton("删除") { _, _ ->
                AccountStore.delete(id)
                SourceFactory.invalidate()
                finish()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun toast(text: String) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show()
    }
}
