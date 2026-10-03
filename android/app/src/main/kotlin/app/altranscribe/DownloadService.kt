package app.altranscribe

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps a model download alive with the screen off or the app in the
 * background, and shows its progress. Dart does the downloading; this service
 * only holds the process in the foreground and mirrors the state it reports.
 */
class DownloadService : Service() {
    companion object { var current: DownloadService? = null }
    private val runtime get() = AppRuntime.get(this)
    private var wake: PowerManager.WakeLock? = null
    private var title = "Altranscribe"
    private var english = false
    private var stage = "connecting"
    private var received = 0L
    private var total = 0L

    override fun onCreate() {
        super.onCreate(); current = this
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "start" -> {
                title = intent.getStringExtra("title") ?: title
                english = intent.getBooleanExtra("english", false)
                stage = "connecting"; received = 0; total = intent.getLongExtra("total", 0)
                getSystemService(NotificationManager::class.java).createNotificationChannel(
                    NotificationChannel("downloads", if (english) "Model downloads" else "模型下载", NotificationManager.IMPORTANCE_LOW))
                try {
                    startForeground(2, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                    if (wake == null) wake = getSystemService(PowerManager::class.java)
                        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "altranscribe:download")
                        .apply { acquire(6 * 60 * 60 * 1000L) }
                } catch (_: Exception) { stopSelf() }
            }
            "cancel" -> runtime.platform.invokeMethod("downloadAction", "cancel")
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }
    fun update(stage: String, received: Long, total: Long) {
        this.stage = stage; this.received = received; this.total = total
        getSystemService(NotificationManager::class.java).notify(2, notification())
    }
    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val cancel = PendingIntent.getService(this, 2, Intent(this, DownloadService::class.java).setAction("cancel"), PendingIntent.FLAG_IMMUTABLE)
        val percent = if (total > 0) (received * 100 / total).toInt().coerceIn(0, 100) else 0
        val waiting = stage == "retrying" || (stage == "connecting" && received == 0L)
        val text = when {
            stage == "retrying" -> if (english) "Connection lost, retrying…" else "连接中断，正在重试…"
            waiting -> if (english) "Connecting…" else "正在连接…"
            else -> "${received / 1_000_000} MB / ${total / 1_000_000} MB · $percent%"
        }
        return Notification.Builder(this, "downloads")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title).setContentText(text)
            .setProgress(100, percent, waiting)
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, if (english) "Cancel" else "取消", cancel).build())
            .build()
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android limits how long a data sync may run; the download stops cleanly.
        runtime.platform.invokeMethod("downloadAction", "cancel")
        stopSelf()
    }
    override fun onDestroy() {
        if (wake?.isHeld == true) wake?.release()
        wake = null; current = null
        super.onDestroy()
    }
}
