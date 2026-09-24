package app.altranscribe

import android.app.*
import android.content.Intent
import android.content.res.Configuration
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager

class CaptureService : Service() {
    companion object { var current: CaptureService? = null }
    private val runtime get() = AppRuntime.get(this)
    private var wake: PowerManager.WakeLock? = null
    private var files = false
    private var finishing = false
    private var completed = false
    private val completionCallbacks = mutableListOf<() -> Unit>()
    override fun onCreate() {
        super.onCreate(); current = this
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("transcription", "Altranscribe", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "start", "files" -> {
                files = intent.action == "files"
                finishing = false; completed = false
                try {
                    var type = if (files) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
                    if (!files && runtime.captureOptions["microphone"] == true) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    if (!files && runtime.captureOptions["system"] == true) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                    startForeground(1, notification(false), type)
                    if (wake == null) wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "altranscribe:capture").apply { acquire() }
                    if (!files) runtime.beginCapture()
                } catch (error: Exception) { runtime.failStart(error); stopSelf() }
            }
            "pause", "stop", "captions" -> runtime.action(intent.action!!)
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }
    private fun notification(paused: Boolean): Notification {
        val english = runtime.captureOptions["interfaceLanguage"] == "en"
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = Notification.Builder(this, "transcription")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now).setContentTitle("Altranscribe")
            .setContentText(if (finishing) { if (english) "Finishing transcript" else "正在完成转录并保存" }
                else if (files) { if (english) "Processing file" else "正在处理文件" }
                else if (paused) { if (english) "Paused" else "已暂停" }
                else { if (english) "Transcribing" else "正在转录" })
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
        fun action(name: String, label: String) {
            val pending = PendingIntent.getService(this, name.hashCode(), Intent(this, CaptureService::class.java).setAction(name), PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(null, label, pending).build())
        }
        if (!files && !finishing) {
            action("pause", if (paused) { if (english) "Resume" else "继续" } else { if (english) "Pause" else "暂停" })
            action("captions", if (english) "Captions" else "悬浮字幕")
        }
        if (!finishing) action("stop", if (english) "Stop and save" else "停止并保存")
        return builder.build()
    }
    fun update(paused: Boolean) = getSystemService(NotificationManager::class.java).notify(1, notification(paused))
    fun finishCapture() {
        finishing = true
        // Keep network decoding/translation and the final save alive after the
        // microphone and projection have been released.
        try { startForeground(1, notification(false), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) }
        catch (_: Exception) { runtime.action("interrupted"); complete() }
    }
    fun complete(done: (() -> Unit)? = null) {
        completed = true
        done?.let { completionCallbacks.add(it) }
        stopSelf()
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        runtime.captions.fitScreen()
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        runtime.action("interrupted")
        complete()
    }
    override fun onDestroy() {
        if (!completed) runtime.action("interrupted")
        if (wake?.isHeld == true) wake?.release()
        wake = null; current = null
        super.onDestroy()
        completionCallbacks.forEach { it() }
        completionCallbacks.clear()
    }
}
