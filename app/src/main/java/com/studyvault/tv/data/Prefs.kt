package com.studyvault.tv.data

import android.content.Context
import android.content.SharedPreferences

/** 本地设置 */
object Prefs {

    private const val PREF = "sv_settings"

    private const val KEY_COLUMNS = "columns"
    private const val KEY_SORT = "sort"
    private const val KEY_ASC = "asc"
    private const val KEY_THUMB = "thumb"

    private lateinit var sp: SharedPreferences

    fun init(context: Context) {
        sp = context.applicationContext.getSharedPreferences(PREF, Context.MODE_PRIVATE)
    }

    /** 网格每行列数 */
    var columns: Int
        get() = sp.getInt(KEY_COLUMNS, 4)
        set(value) = sp.edit().putInt(KEY_COLUMNS, value).apply()

    /** 排序方式：name / date / size */
    var sortBy: String
        get() = sp.getString(KEY_SORT, SORT_NAME) ?: SORT_NAME
        set(value) = sp.edit().putString(KEY_SORT, value).apply()

    /** 是否升序 */
    var ascending: Boolean
        get() = sp.getBoolean(KEY_ASC, true)
        set(value) = sp.edit().putBoolean(KEY_ASC, value).apply()

    /** 是否显示缩略图（老盒子可以关掉提速） */
    var thumbnails: Boolean
        get() = sp.getBoolean(KEY_THUMB, true)
        set(value) = sp.edit().putBoolean(KEY_THUMB, value).apply()

    const val SORT_NAME = "name"
    const val SORT_DATE = "date"
    const val SORT_SIZE = "size"
}
