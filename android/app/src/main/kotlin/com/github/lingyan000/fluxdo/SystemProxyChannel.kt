package com.github.lingyan000.fluxdo

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 安卓系统 HTTP 代理（Wi-Fi 里手动配的代理、PAC，或 VPN 通过
 * VpnService.Builder.setHttpProxy 下发的代理）的只读通道。
 *
 * 读的是本 App 默认网络上的代理（ConnectivityManager.getDefaultProxy），与系统浏览器
 * 看到的一致。Dart 侧 SystemProxyService 周期读取，网关据此把上游出口换成这个代理，
 * 保持内置网页与原生请求同一出口。
 */
object SystemProxyChannel {
    private const val CHANNEL = "fluxdo/system_proxy"

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "read") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                result.success(read(appContext))
            } catch (e: Exception) {
                result.error("read_failed", e.message, null)
            }
        }
    }

    fun dispose(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(null)
    }

    private fun read(context: Context): Map<String, Any?> {
        // getDefaultProxy 是 API 23 起才有的；更老的系统当没有代理
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyMap()
        val cm = context.getSystemService(ConnectivityManager::class.java)
            ?: return emptyMap()
        val proxy = cm.defaultProxy ?: return emptyMap()
        val pac = proxy.pacFileUrl?.toString()?.takeIf { it.isNotBlank() && it != "about:blank" }
        val host = proxy.host?.takeIf { it.isNotBlank() }
        return mapOf(
            "host" to host,
            "port" to proxy.port,
            "pac" to pac,
            "exclusions" to (proxy.exclusionList?.toList() ?: emptyList<String>()),
        )
    }
}
