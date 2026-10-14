package com.studyvault.tv.data

/**
 * 当前生效的数据源。切换账号时关掉旧的、建新的。
 */
object SourceFactory {

    @Volatile
    private var cachedId: String? = null

    @Volatile
    private var cached: RemoteSource? = null

    fun get(account: ServerAccount): RemoteSource {
        val existing = cached
        if (existing != null && cachedId == account.id) return existing
        synchronized(this) {
            if (cached == null || cachedId != account.id) {
                try {
                    cached?.close()
                } catch (e: Exception) {
                    // ignore
                }
                cached = when (account.type) {
                    ProtocolType.SMB -> SmbSource(account)
                    ProtocolType.WEBDAV -> WebDavSource(account)
                }
                cachedId = account.id
            }
            return cached ?: SmbSource(account)
        }
    }

    fun invalidate() {
        synchronized(this) {
            try {
                cached?.close()
            } catch (e: Exception) {
                // ignore
            }
            cached = null
            cachedId = null
        }
    }
}
