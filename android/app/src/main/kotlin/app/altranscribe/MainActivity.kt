package app.altranscribe

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.DragEvent
import android.view.View
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {
    private val runtime get() = AppRuntime.get(this)
    private var capture: Pair<Map<String, Any?>, MethodChannel.Result>? = null
    private var picker: MethodChannel.Result? = null
    private var saver: Pair<ByteArray, MethodChannel.Result>? = null
    private var scanner: MethodChannel.Result? = null
    private var overlay: (() -> Unit)? = null
    override fun provideFlutterEngine(context: Context): FlutterEngine = runtime.engine
    override fun shouldDestroyEngineWithHost() = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) { /* Registered by AppRuntime. */ }
    override fun onCreate(savedInstanceState: Bundle?) {
        runtime.activity = WeakReference(this)
        super.onCreate(savedInstanceState)
        importIntent(intent)
        // Accept content URI drops from Android multi-window document providers.
        findViewById<View>(android.R.id.content).setOnDragListener { _, event ->
            when (event.action) {
                DragEvent.ACTION_DRAG_STARTED -> event.clipDescription?.hasMimeType("audio/*") == true || event.clipDescription?.hasMimeType("video/*") == true || event.clipDescription?.hasMimeType("application/ogg") == true
                DragEvent.ACTION_DROP -> {
                    val permission = requestDragAndDropPermissions(event)
                    val paths = (0 until event.clipData.itemCount).mapNotNull { event.clipData.getItemAt(it).uri }.map { document(it, false) }
                    runtime.importFiles(paths)
                    // Retain the temporary grant while the document is used.
                    if (paths.isEmpty()) permission?.release()
                    true
                }
                else -> true
            }
        }
    }
    override fun onResume() { super.onResume(); runtime.activity = WeakReference(this) }
    override fun onDestroy() {
        if (runtime.activity.get() == this) runtime.activity.clear()
        capture?.second?.error("androidActivityClosed", "Capture authorization cancelled", null)
        capture = null
        picker?.success(emptyList<String>()); picker = null
        saver?.second?.success(false); saver = null
        scanner?.success(null); scanner = null
        super.onDestroy()
    }
    fun scanQr(hint: String, result: MethodChannel.Result) {
        if (scanner != null) { result.error("busy", "Scanner already open", null); return }
        scanner = result
        startActivityForResult(Intent(this, ScanActivity::class.java).putExtra(ScanActivity.EXTRA_HINT, hint), 106)
    }
    fun saveDocument(name: String, mime: String, bytes: ByteArray, result: MethodChannel.Result) {
        if (saver != null) { result.error("busy", "Save dialog already open", null); return }
        saver = bytes to result
        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).setType(mime)
            .addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, name), 105)
    }
    fun openDocument(uri: String, result: MethodChannel.Result) {
        val target = Uri.parse(uri).buildUpon().fragment(null).build()
        try {
            // A viewer would only show its own error for a deleted document, so probe it first.
            (contentResolver.openInputStream(target) ?: throw java.io.FileNotFoundException(uri)).close()
            startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(target, contentResolver.getType(target) ?: "*/*")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            result.success(null)
        } catch (error: java.io.FileNotFoundException) { result.error("sourceFileMissing", error.message, null)
        } catch (error: Exception) { result.error("fileOpenFailed", error.message, null) }
    }
    fun shareFile(path: String, mime: String, result: MethodChannel.Result) {
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.files", File(path))
            startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType(mime)
                .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), null))
            result.success(null)
        } catch (error: Exception) { result.error("shareFailed", error.message, null) }
    }
    fun prepareCapture(options: Map<String, Any?>, result: MethodChannel.Result) {
        if (capture != null) { result.error("busy", "Capture authorization is pending", null); return }
        capture = options to result
        val permissions = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) permissions.add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        if (permissions.isNotEmpty()) requestPermissions(permissions.toTypedArray(), 101) else authorizeProjection()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 101) {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) authorizeProjection()
            else { capture?.second?.error("androidMicrophonePermission", "Audio permission denied", null); capture = null }
        }
    }
    private fun authorizeProjection() {
        val pending = capture ?: return
        if (pending.first["system"] == true) {
            startActivityForResult(getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent(), 102)
        } else { capture = null; runtime.startCapture(pending.first, Activity.RESULT_CANCELED, null, pending.second) }
    }
    fun chooseFiles(result: MethodChannel.Result) {
        if (picker != null) { result.error("busy", "File picker already open", null); return }
        picker = result
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*")
            .addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("audio/*", "video/*", "application/ogg"))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), 103)
    }
    fun authorizeOverlay(ready: () -> Unit) {
        overlay = ready
        startActivityForResult(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")), 104)
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            102 -> {
                val pending = capture; capture = null
                if (pending != null) {
                    if (resultCode == Activity.RESULT_OK && data != null) runtime.startCapture(pending.first, resultCode, data, pending.second)
                    else pending.second.error("androidSystemAudioPermission", "System audio authorization cancelled", null)
                }
            }
            103 -> { picker?.success(if (resultCode == Activity.RESULT_OK && data != null) documents(data) else emptyList<String>()); picker = null }
            104 -> { val ready = overlay; overlay = null; ready?.invoke() }
            105 -> {
                val pending = saver; saver = null
                val target = data?.data
                if (pending == null) return
                if (resultCode != Activity.RESULT_OK || target == null) { pending.second.success(false); return }
                try {
                    contentResolver.openOutputStream(target, "wt")?.use { it.write(pending.first) } ?: throw IllegalStateException("No output stream")
                    pending.second.success(true)
                } catch (error: Exception) { pending.second.error("exportFailed", error.message, null) }
            }
            106 -> {
                val pending = scanner; scanner = null
                if (pending == null) return
                if (data?.getBooleanExtra(ScanActivity.EXTRA_DENIED, false) == true) pending.error("cameraDenied", "Camera permission denied", null)
                else pending.success(if (resultCode == Activity.RESULT_OK) data?.getStringExtra(ScanActivity.EXTRA_TEXT) else null)
            }
        }
    }
    private fun documents(intent: Intent): List<String> {
        val uris = mutableListOf<Uri>()
        intent.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) } }
        intent.data?.let { uris.add(it) }
        if (intent.action == Intent.ACTION_SEND) intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        return uris.distinct().map { document(it, intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) }
    }
    private fun document(uri: Uri, persist: Boolean): String {
        if (persist) try { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) } catch (_: SecurityException) { }
        var name = uri.lastPathSegment ?: "Audio"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) name = cursor.getString(0)
        }
        return uri.buildUpon().fragment(name).build().toString()
    }
    private fun importIntent(intent: Intent) {
        if (intent.action in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) runtime.importFiles(documents(intent))
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); importIntent(intent) }
}
