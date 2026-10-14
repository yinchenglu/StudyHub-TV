package com.studyvault.tv.data

import android.content.Context
import android.content.SharedPreferences
import com.studyvault.tv.util.Crypto
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * 账号仓库：把多个服务器账号存成一段 JSON 放在 SharedPreferences 里。
 * V1 的账号量很小（个位数），用不着数据库，这样依赖更少、更不容易出问题。
 */
object AccountStore {

    private const val PREF = "sv_accounts"
    private const val KEY_LIST = "list"
    private const val KEY_CURRENT = "current_id"

    private lateinit var sp: SharedPreferences

    fun init(context: Context) {
        sp = context.applicationContext.getSharedPreferences(PREF, Context.MODE_PRIVATE)
    }

    fun all(): MutableList<ServerAccount> {
        val raw = sp.getString(KEY_LIST, null)
        val out = mutableListOf<ServerAccount>()
        if (raw.isNullOrEmpty()) return out
        try {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(fromJson(o))
            }
        } catch (e: Exception) {
            // 配置损坏时不要崩，返回空列表让用户重新添加
        }
        return out
    }

    fun get(id: String): ServerAccount? = all().firstOrNull { it.id == id }

    fun save(account: ServerAccount) {
        val list = all()
        val idx = list.indexOfFirst { it.id == account.id }
        if (idx >= 0) list[idx] = account else list.add(account)
        persist(list)
    }

    fun delete(id: String) {
        val list = all()
        list.removeAll { it.id == id }
        persist(list)
        if (currentId() == id) {
            sp.edit().remove(KEY_CURRENT).apply()
        }
    }

    fun currentId(): String? = sp.getString(KEY_CURRENT, null)

    fun setCurrent(id: String) {
        sp.edit().putString(KEY_CURRENT, id).apply()
    }

    fun current(): ServerAccount? {
        val id = currentId() ?: return null
        return get(id)
    }

    fun newId(): String = UUID.randomUUID().toString()

    private fun persist(list: List<ServerAccount>) {
        val arr = JSONArray()
        list.forEach { arr.put(toJson(it)) }
        sp.edit().putString(KEY_LIST, arr.toString()).apply()
    }

    private fun toJson(a: ServerAccount): JSONObject = JSONObject().apply {
        put("id", a.id)
        put("name", a.name)
        put("type", a.type.name)
        put("host", a.host)
        put("port", a.port)
        put("share", a.share)
        put("rootPath", a.rootPath)
        put("username", a.username)
        put("pwd", Crypto.encrypt(a.password))
        put("https", a.https)
    }

    private fun fromJson(o: JSONObject): ServerAccount {
        val type = try {
            ProtocolType.valueOf(o.optString("type", ProtocolType.SMB.name))
        } catch (e: Exception) {
            ProtocolType.SMB
        }
        return ServerAccount(
            id = o.optString("id"),
            name = o.optString("name"),
            type = type,
            host = o.optString("host"),
            port = o.optInt("port", type.defaultPort),
            share = o.optString("share"),
            rootPath = o.optString("rootPath", "/"),
            username = o.optString("username"),
            password = Crypto.decrypt(o.optString("pwd")),
            https = o.optBoolean("https", false)
        )
    }
}
