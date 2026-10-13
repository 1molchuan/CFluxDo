package com.github.lingyan000.fluxdo

import android.app.Application
import android.util.Log
import android.webkit.WebView

class FluxdoApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        try {
            WebView.setWebContentsDebuggingEnabled(false)
            Log.i("WebViewDebug", "WebView debugging disabled in Application.onCreate")
        } catch (e: Throwable) {
            Log.e("WebViewDebug", "Failed to disable WebView debugging early: ${e.message}", e)
        }
        // 金标联盟公平运行内存机制:进程级注册 TRIM 广播接收器
        // (非联盟 ROM 收不到该广播,注册零成本)
        FairMemoryReceiver.initialize(this)
    }
}
