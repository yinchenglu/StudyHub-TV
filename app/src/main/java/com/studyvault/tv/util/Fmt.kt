package com.studyvault.tv.util

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object Fmt {

    fun size(bytes: Long): String {
        if (bytes < 0) return "-"
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return String.format(Locale.ROOT, "%.1f KB", kb)
        val mb = kb / 1024.0
        if (mb < 1024) return String.format(Locale.ROOT, "%.1f MB", mb)
        val gb = mb / 1024.0
        return String.format(Locale.ROOT, "%.2f GB", gb)
    }

    fun duration(ms: Long): String {
        if (ms <= 0) return "00:00"
        val total = ms / 1000
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s)
        else String.format(Locale.ROOT, "%02d:%02d", m, s)
    }

    fun date(ts: Long): String {
        if (ts <= 0) return "-"
        return try {
            SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date(ts))
        } catch (e: Exception) {
            "-"
        }
    }
}
