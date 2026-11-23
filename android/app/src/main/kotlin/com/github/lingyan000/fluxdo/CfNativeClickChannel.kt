package com.github.lingyan000.fluxdo

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

/**
 * 验证页替用户点 Turnstile 勾选框：往 Dart 指定的那个 WebView（按 platform view id）
 * 注入一次手指触摸。找不到这个 WebView 就不点，绝不退到别的 WebView 上。
 *
 * 返回 `{ok: true}` 只表示 down/move/up 已全部送进目标 WebView；点没点中由 Dart 侧
 * 看 Turnstile 的反馈判断。
 */
object CfNativeClickChannel {
    private const val TAG = "CfNativeClick"
    private const val CHANNEL = "com.fluxdo/cf_native_click"

    private const val MOVE_DELAY_MS = 24L
    private const val UP_DELAY_MS = 86L

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "tap") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val viewId = (call.argument<Any>("viewId") as? Number)?.toInt()
            val nx = (call.argument<Any>("nx") as? Number)?.toDouble()
            val ny = (call.argument<Any>("ny") as? Number)?.toDouble()
            if (viewId == null || nx == null || ny == null ||
                nx !in 0.0..1.0 || ny !in 0.0..1.0
            ) {
                result.success(failure("bad_args"))
                return@setMethodCallHandler
            }
            try {
                val platformView = engine.platformViewsControllerDelegator.getPlatformViewById(viewId)
                val webView = findSingleWebView(platformView)
                if (webView == null) {
                    Log.w(TAG, "viewId=$viewId 下没有唯一的 WebView，不点")
                    result.success(failure("view_not_found"))
                    return@setMethodCallHandler
                }
                tap(webView, nx, ny) { outcome -> result.success(outcome) }
            } catch (e: Exception) {
                Log.w(TAG, "查找目标 WebView 失败: ${e.message}")
                result.success(failure("exception: ${e.message}"))
            }
        }
    }

    fun dispose(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(null)
    }

    private fun failure(reason: String) = mapOf("ok" to false, "reason" to reason)

    /** platform view 本身是 WebView，或其子树里恰好只有一个 WebView（下拉刷新外壳） */
    private fun findSingleWebView(root: View?): WebView? {
        val found = mutableListOf<WebView>()
        collectWebViews(root, found)
        return found.singleOrNull()
    }

    private fun collectWebViews(view: View?, out: MutableList<WebView>) {
        when (view) {
            is WebView -> out.add(view)
            is ViewGroup -> for (index in 0 until view.childCount) {
                collectWebViews(view.getChildAt(index), out)
            }
        }
    }

    private fun tap(webView: WebView, nx: Double, ny: Double, done: (Map<String, Any>) -> Unit) {
        val width = webView.width
        val height = webView.height
        if (width <= 0 || height <= 0 || !webView.isAttachedToWindow) {
            done(failure("view_not_laid_out"))
            return
        }
        val x = (nx * width).toFloat()
        val y = (ny * height).toFloat()
        val downTime = SystemClock.uptimeMillis()
        // 手指在屏幕上会有一点点漂移
        val driftX = 0.6f
        val driftY = 0.4f

        // 后两段在 postDelayed 里跑，异常不能漏出去，否则 Dart 侧永远等不到回复
        fun send(action: Int, px: Float, py: Float): Boolean {
            if (!webView.isAttachedToWindow) return false
            val event = fingerEvent(downTime, SystemClock.uptimeMillis(), action, px, py)
            return try {
                webView.dispatchTouchEvent(event)
                true
            } catch (e: Exception) {
                Log.w(TAG, "dispatchTouchEvent 失败: ${e.message}")
                false
            } finally {
                event.recycle()
            }
        }

        if (!send(MotionEvent.ACTION_DOWN, x, y)) {
            done(failure("detached"))
            return
        }
        webView.postDelayed({
            if (!send(MotionEvent.ACTION_MOVE, x + driftX, y + driftY)) {
                done(failure("detached"))
                return@postDelayed
            }
            webView.postDelayed({
                if (!send(MotionEvent.ACTION_UP, x + driftX, y + driftY)) {
                    done(failure("detached"))
                    return@postDelayed
                }
                Log.i(TAG, "已注入触摸 (${x.toInt()}, ${y.toInt()}) size=${width}x$height")
                done(mapOf("ok" to true))
            }, UP_DELAY_MS - MOVE_DELAY_MS)
        }, MOVE_DELAY_MS)
    }

    private fun fingerEvent(
        downTime: Long,
        eventTime: Long,
        action: Int,
        x: Float,
        y: Float,
    ): MotionEvent {
        val properties = MotionEvent.PointerProperties().apply {
            id = 0
            toolType = MotionEvent.TOOL_TYPE_FINGER
        }
        val coords = MotionEvent.PointerCoords().apply {
            this.x = x
            this.y = y
            pressure = if (action == MotionEvent.ACTION_UP) 0f else 0.65f
            size = 0.08f
            touchMajor = 18f
            touchMinor = 16f
        }
        return MotionEvent.obtain(
            downTime,
            eventTime,
            action,
            1,
            arrayOf(properties),
            arrayOf(coords),
            0,
            0,
            1f,
            1f,
            touchscreenDeviceId(),
            0,
            InputDevice.SOURCE_TOUCHSCREEN,
            0,
        )
    }

    private fun touchscreenDeviceId(): Int =
        InputDevice.getDeviceIds().firstOrNull { id ->
            InputDevice.getDevice(id)?.supportsSource(InputDevice.SOURCE_TOUCHSCREEN) == true
        } ?: 0
}
