package app.altranscribe

import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.FlutterInjector
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/** System overlay hosting the Flutter caption panel. */
class CaptionOverlay(private val runtime: AppRuntime) {
    private val context = runtime.context
    private val windows = context.getSystemService(WindowManager::class.java)
    private val mainChannel = MethodChannel(runtime.engine.dartExecutor.binaryMessenger, "altranscribe/captions")
    private var engine: FlutterEngine? = null
    private var view: FlutterView? = null
    private var channel: MethodChannel? = null
    private var data: Any? = null
    private var params: WindowManager.LayoutParams? = null
    private val density get() = context.resources.displayMetrics.density
    private fun pixels(dp: Double) = (dp * density).roundToInt()

    init {
        mainChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show", "update" -> {
                    data = call.arguments
                    if (Settings.canDrawOverlays(context)) display(result)
                    else runtime.withActivity(result) { activity -> activity.authorizeOverlay {
                        if (Settings.canDrawOverlays(context)) display(result)
                        else result.error("androidOverlayPermission", "Overlay permission denied", null)
                    } }
                }
                "hide" -> { hide(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }
    private fun display(result: MethodChannel.Result) {
        try {
            if (engine == null) {
                val secondary = FlutterEngine(context, null, false)
                engine = secondary
                channel = MethodChannel(secondary.dartExecutor.binaryMessenger, "altranscribe/captions").also { bridge ->
                    bridge.setMethodCallHandler { call, reply ->
                        when (call.method) {
                            "ready" -> reply.success(data)
                            "action" -> mainChannel.invokeMethod("action", call.arguments, reply)
                            "drag" -> reply.success(null)
                            "move", "resize" -> {
                                val delta = call.arguments as Map<*, *>
                                move((delta["dx"] as Number).toDouble(), (delta["dy"] as Number).toDouble(), call.method == "resize")
                                reply.success(null)
                            }
                            else -> reply.notImplemented()
                        }
                    }
                }
                secondary.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
                    FlutterInjector.instance().flutterLoader().findAppBundlePath(), "package:altranscribe/main.dart", "captionMain"))
            }
            if (view == null) {
                val texture = FlutterTextureView(context).also { it.isOpaque = false }
                val flutter = FlutterView(context, texture)
                flutter.background = GradientDrawable().apply { cornerRadius = pixels(24.0).toFloat(); setColor(0xFF000000.toInt()) }
                flutter.clipToOutline = true
                flutter.attachToFlutterEngine(engine!!)
                val metrics = context.resources.displayMetrics
                val layout = params ?: WindowManager.LayoutParams(
                    minOf(pixels(380.0), metrics.widthPixels - pixels(16.0)),
                    minOf(pixels(290.0), metrics.heightPixels / 2),
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    PixelFormat.TRANSLUCENT).apply {
                        gravity = Gravity.TOP or Gravity.LEFT
                        x = pixels(8.0); y = pixels(80.0)
                    }
                params = layout
                windows.addView(flutter, layout)
                view = flutter
                engine!!.lifecycleChannel.appIsResumed()
                engine!!.lifecycleChannel.aWindowIsFocused()
            }
            val preferences = (data as? Map<*, *>)?.get("preferences") as? Map<*, *>
            params!!.alpha = ((preferences?.get("opacity") as? Number)?.toFloat() ?: .94f).coerceIn(.4f, 1f)
            windows.updateViewLayout(view, params)
            channel!!.invokeMethod("snapshot", data)
            result.success(null)
        } catch (error: Exception) {
            hide()
            result.error("androidOverlay", error.message, null)
        }
    }
    private fun move(dx: Double, dy: Double, resize: Boolean) {
        val layout = params ?: return
        val metrics = context.resources.displayMetrics
        if (resize) {
            layout.width = (layout.width + pixels(dx)).coerceIn(minOf(pixels(320.0), metrics.widthPixels), metrics.widthPixels)
            layout.height = (layout.height + pixels(dy)).coerceIn(minOf(pixels(220.0), metrics.heightPixels), metrics.heightPixels)
        } else { layout.x += pixels(dx); layout.y += pixels(dy) }
        layout.x = layout.x.coerceIn(0, maxOf(0, metrics.widthPixels - layout.width))
        layout.y = layout.y.coerceIn(0, maxOf(0, metrics.heightPixels - layout.height))
        view?.let { windows.updateViewLayout(it, layout) }
    }
    fun fitScreen() = move(0.0, 0.0, true)
    fun hide() {
        channel?.invokeMethod("hidden", null)
        view?.let { it.detachFromFlutterEngine(); windows.removeView(it) }
        view = null
        engine?.lifecycleChannel?.appIsPaused()
    }
}
