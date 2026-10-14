package com.studyvault.tv.util

import android.content.Context
import android.util.Base64
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 服务器密码的落盘加密工具。
 *
 * 说明：密钥随机生成后保存在应用私有目录里，作用是「不让密码以明文出现在配置文件里」，
 * 属于防窥级别，不等同于系统级安全存储（安卓 5 上也没有可用的 EncryptedSharedPreferences）。
 */
object Crypto {

    private const val PREF = "sv_secure"
    private const val KEY_SECRET = "k"
    private const val TRANSFORM = "AES/CBC/PKCS5Padding"

    private var secret: SecretKeySpec? = null

    fun init(context: Context) {
        val sp = context.applicationContext.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        var raw = sp.getString(KEY_SECRET, null)
        if (raw.isNullOrEmpty()) {
            val bytes = ByteArray(16)
            SecureRandom().nextBytes(bytes)
            raw = Base64.encodeToString(bytes, Base64.NO_WRAP)
            sp.edit().putString(KEY_SECRET, raw).apply()
        }
        secret = SecretKeySpec(Base64.decode(raw, Base64.NO_WRAP), "AES")
    }

    fun encrypt(plain: String): String {
        if (plain.isEmpty()) return ""
        val key = secret ?: return ""
        return try {
            val iv = ByteArray(16)
            SecureRandom().nextBytes(iv)
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.ENCRYPT_MODE, key, IvParameterSpec(iv))
            val body = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
            Base64.encodeToString(iv + body, Base64.NO_WRAP)
        } catch (e: Exception) {
            ""
        }
    }

    fun decrypt(cipherText: String): String {
        if (cipherText.isEmpty()) return ""
        val key = secret ?: return ""
        return try {
            val all = Base64.decode(cipherText, Base64.NO_WRAP)
            if (all.size <= 16) return ""
            val iv = all.copyOfRange(0, 16)
            val body = all.copyOfRange(16, all.size)
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, key, IvParameterSpec(iv))
            String(cipher.doFinal(body), Charsets.UTF_8)
        } catch (e: Exception) {
            ""
        }
    }
}
