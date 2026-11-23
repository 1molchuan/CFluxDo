package com.github.lingyan000.fluxdo

import android.app.Activity
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object CfNativeClickChannel {
    private const val TAG = "CfNativeClick"
    private const val CHANNEL = "com.fluxdo/cf_native_click"

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "tap") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val viewId = (call.argument<Any>("viewId") as? Number)?.toInt()
            val host = call.argument<String>("host")
            val nx = call.argument<Double>("nx")
            val ny = call.argument<Double>("ny")
            if (nx == null || ny == null) {
                result.error("bad_args", "nx/ny 不能为空", null)
                return@setMethodCallHandler
            }
            try {
                val webView = findWebView(activity, engine, viewId, host)
                if (webView == null) {
                    Log.w(TAG, "找不到目标 WebView (viewId=$viewId, host=$host)")
                    result.success(false)
                    return@setMethodCallHandler
                }
                result.success(tap(webView, nx, ny))
            } catch (e: Exception) {
                Log.w(TAG, "原生输入失败: ${e.message}")
                result.error("tap_failed", e.message, null)
            }
        }
    }

    fun dispose(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(null)
    }

    private fun findWebView(
        activity: Activity,
        engine: FlutterEngine,
        viewId: Int?,
        host: String?,
    ): WebView? {
        if (viewId != null) {
            val platformView = engine.platformViewsControllerDelegator.getPlatformViewById(viewId)
            pick(collectWebViews(platformView), host)?.let { return it }
        }
        val candidates = mutableListOf<WebView>()
        collectWebViews(activity.window?.decorView, candidates)
        return pick(candidates, host)
    }

    private fun collectWebViews(view: View?): List<WebView> {
        val result = mutableListOf<WebView>()
        collectWebViews(view, result)
        return result
    }

    private fun collectWebViews(view: View?, out: MutableList<WebView>) {
        when (view) {
            is WebView -> out.add(view)
            is ViewGroup -> {
                for (index in 0 until view.childCount) {
                    collectWebViews(view.getChildAt(index), out)
                }
            }
        }
    }

    private fun pick(candidates: List<WebView>, host: String?): WebView? {
        if (candidates.isEmpty()) return null
        if (host != null) {
            candidates.firstOrNull {
                it.url?.contains(host, ignoreCase = true) == true ||
                    it.originalUrl?.contains(host, ignoreCase = true) == true
            }?.let { return it }
        }
        return candidates.maxByOrNull { it.width.toLong() * it.height.toLong() }
    }

    private fun tap(webView: WebView, nx: Double, ny: Double): Boolean {
        val width = if (webView.width > 0) webView.width else webView.measuredWidth
        val height = if (webView.height > 0) webView.height else webView.measuredHeight
        if (width <= 0 || height <= 0) {
            Log.w(TAG, "WebView 尺寸无效 (${width}x$height)")
            return false
        }
        val x = (nx.coerceIn(0.0, 1.0) * width).toFloat()
        val y = (ny.coerceIn(0.0, 1.0) * height).toFloat()
        val downTime = SystemClock.uptimeMillis()

        fun event(eventTime: Long, action: Int, px: Float, py: Float): MotionEvent =
            MotionEvent.obtain(
                downTime,
                eventTime,
                action,
                px,
                py,
                1f,
                0.08f,
                0,
                1f,
                1f,
                0,
                0,
            ).apply { source = InputDevice.SOURCE_TOUCHSCREEN }

        val down = event(downTime, MotionEvent.ACTION_DOWN, x, y)
        val move = event(downTime + 16, MotionEvent.ACTION_MOVE, x + 0.6f, y + 0.6f)
        val up = event(downTime + 72, MotionEvent.ACTION_UP, x + 0.6f, y + 0.6f)

        return try {
            val downHandled = webView.dispatchTouchEvent(down)
            webView.dispatchTouchEvent(move)
            val upHandled = webView.dispatchTouchEvent(up)
            Log.i(TAG, "dispatchTouchEvent (${x.toInt()}, ${y.toInt()}) size=${width}x$height")
            downHandled || upHandled
        } finally {
            down.recycle()
            move.recycle()
            up.recycle()
        }
    }
}
