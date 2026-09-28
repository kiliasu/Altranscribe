package app.altranscribe

import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
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
    private var pointer = -1
    private var gesture = 0 // 0: pending, 1: drag, 2: resize
    private var downX = 0f; private var downY = 0f
    private var touchX = 0f; private var touchY = 0f
    private var startX = 0; private var startY = 0
    private var startWidth = 0; private var startHeight = 0
    private var framePending = false
    private val moveFrame = Runnable { framePending = false; applyGesture() }
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
                            "drag", "resize" -> {
                                if (pointer != -1) {
                                    gesture = if (call.method == "resize") 2 else 1
                                    scheduleMove()
                                }
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
                // Flutter coordinates move with this window. Keep the gesture's
                // screen-space anchor here; Flutter only identifies its handle.
                flutter.setOnTouchListener { _, event -> trackTouch(event); false }
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
            val alpha = ((preferences?.get("opacity") as? Number)?.toFloat() ?: .94f).coerceIn(.4f, 1f)
            if (params!!.alpha != alpha) {
                params!!.alpha = alpha
                windows.updateViewLayout(view, params)
            }
            channel!!.invokeMethod("snapshot", data)
            result.success(null)
        } catch (error: Exception) {
            hide()
            result.error("androidOverlay", error.message, null)
        }
    }
    private fun trackTouch(event: MotionEvent) {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            endGesture()
            val flutter = view ?: return
            pointer = event.getPointerId(0)
            downX = event.rawX; downY = event.rawY
            touchX = downX; touchY = downY
            // WindowManager may have constrained the window after rotation or
            // at a display inset without changing our requested LayoutParams.
            val position = IntArray(2)
            flutter.getLocationOnScreen(position)
            startX = position[0]; startY = position[1]
            startWidth = flutter.width; startHeight = flutter.height
        }
        val index = event.findPointerIndex(pointer)
        if (index < 0) return
        touchX = event.getRawX(index); touchY = event.getRawY(index)
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> if (gesture != 0) scheduleMove()
            MotionEvent.ACTION_UP -> { applyGesture(); endGesture() }
            MotionEvent.ACTION_CANCEL -> endGesture()
            MotionEvent.ACTION_POINTER_UP -> if (event.getPointerId(event.actionIndex) == pointer) {
                applyGesture(); endGesture()
            }
        }
    }
    private fun scheduleMove() {
        if (!framePending) {
            framePending = true
            view?.postOnAnimation(moveFrame)
        }
    }
    private fun applyGesture() {
        if (pointer == -1 || gesture == 0) return
        val dx = (touchX - downX).roundToInt()
        val dy = (touchY - downY).roundToInt()
        if (gesture == 2) layoutWindow(startX, startY, startWidth + dx, startHeight + dy)
        else layoutWindow(startX + dx, startY + dy, startWidth, startHeight)
    }
    private fun endGesture() {
        view?.removeCallbacks(moveFrame)
        framePending = false
        pointer = -1
        gesture = 0
    }
    private fun layoutWindow(x: Int, y: Int, width: Int, height: Int) {
        val layout = params ?: return
        val metrics = context.resources.displayMetrics
        val w = width.coerceIn(minOf(pixels(320.0), metrics.widthPixels), metrics.widthPixels)
        val h = height.coerceIn(minOf(pixels(220.0), metrics.heightPixels), metrics.heightPixels)
        val left = x.coerceIn(0, maxOf(0, metrics.widthPixels - w))
        val top = y.coerceIn(0, maxOf(0, metrics.heightPixels - h))
        if (layout.x == left && layout.y == top && layout.width == w && layout.height == h) return
        layout.x = left; layout.y = top; layout.width = w; layout.height = h
        view?.let { windows.updateViewLayout(it, layout) }
    }
    fun fitScreen() {
        endGesture()
        params?.let { layoutWindow(it.x, it.y, it.width, it.height) }
    }
    fun hide() {
        endGesture()
        channel?.invokeMethod("hidden", null)
        view?.let { it.detachFromFlutterEngine(); windows.removeView(it) }
        view = null
        engine?.lifecycleChannel?.appIsPaused()
    }
}
