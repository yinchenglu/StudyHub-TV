package com.studyvault.tv

import android.app.Application
import com.studyvault.tv.data.AccountStore
import com.studyvault.tv.data.Prefs
import com.studyvault.tv.util.Crypto

class App : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this
        Crypto.init(this)
        AccountStore.init(this)
        Prefs.init(this)
    }

    companion object {
        lateinit var instance: App
            private set
    }
}
