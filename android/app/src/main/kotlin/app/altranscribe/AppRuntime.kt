package app.altranscribe

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The foreground service keeps this engine alive when the activity is hidden. */
class AppRuntime private constructor(val context: Context) {
    companion object {
        private var instance: AppRuntime? = null
        fun get(context: Context): AppRuntime = instance ?: AppRuntime(context.applicationContext).also { instance = it }
    }
    val main = Handler(Looper.getMainLooper())
    val audio = AudioCapture(context)
    val engine = FlutterEngine(context)
    val platform = MethodChannel(engine.dartExecutor.binaryMessenger, "altranscribe/platform")
    val captions = CaptionOverlay(this)
    private val io = Executors.newSingleThreadExecutor()
    var activity = WeakReference<MainActivity>(null)
    var captureOptions = emptyMap<String, Any?>()
    private var startResult: MethodChannel.Result? = null
    private var projectionCode = Activity.RESULT_CANCELED
    private var projectionData: Intent? = null
    var pendingFiles = emptyList<String>()
    private val files = AudioFileReader(context)

    init {
        platform.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> async(result) {
                    val model = File(context.filesDir, "rnnoise-model.bin")
                    if (!model.exists()) context.assets.open("rnnoise-model.bin").use { input ->
                        model.outputStream().use { output -> input.copyTo(output) }
                    }
                    val data = File(context.filesDir, "records").also { it.mkdirs() }
                    // Logs live in the app's external folder so they can be pulled or shared.
                    val logs = File(context.getExternalFilesDir(null) ?: context.filesDir, "logs").also { it.mkdirs() }
                    mapOf("dataDirectory" to data.path, "logDirectory" to logs.path, "deviceName" to Build.MODEL)
                }
                "pendingFiles" -> { result.success(pendingFiles); pendingFiles = emptyList() }
                "chooseFiles" -> withActivity(result) { it.chooseFiles(result) }
                "saveDocument" -> withActivity(result) {
                    it.saveDocument(call.argument<String>("name")!!, call.argument<String>("mime")!!, call.argument<ByteArray>("bytes")!!, result)
                }
                "openDocument" -> withActivity(result) { it.openDocument(call.argument<String>("uri")!!, result) }
                "readDocument" -> async(result) { readDocument(call.argument<String>("uri")!!) }
                "shareFile" -> withActivity(result) { it.shareFile(call.argument<String>("path")!!, call.argument<String>("mime")!!, result) }
                "scanQr" -> withActivity(result) { it.scanQr(call.argument<String>("hint") ?: "", result) }
                "backgroundWork" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    try {
                        call.argument<String>("interfaceLanguage")?.let { captureOptions = captureOptions + ("interfaceLanguage" to it) }
                        val service = CaptureService.current
                        if (enabled) {
                            context.startForegroundService(Intent(context, CaptureService::class.java).setAction("files"))
                            result.success(null)
                        } else if (!audio.running && service != null) {
                            service.complete { result.success(null) }
                        } else result.success(null)
                    } catch (error: Exception) { result.error("androidBackgroundWork", error.message, null) }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "altranscribe/audio").setMethodCallHandler { call, result ->
            when (call.method) {
                "devices" -> async(result) { audio.devices() }
                "start" -> withActivity(result) { it.prepareCapture(call.arguments as Map<String, Any?>, result) }
                "poll" -> result.success(audio.poll())
                "pause" -> async(result) {
                    val paused = call.argument<Boolean>("paused") == true
                    audio.pause(paused)
                    main.post { CaptureService.current?.update(paused) }
                    null
                }
                "stop" -> async(result) {
                    val final = audio.stop()
                    main.post { CaptureService.current?.finishCapture() }
                    final
                }
                "protectSecret", "unprotectSecret" -> async(result) {
                    protect(call.argument<ByteArray>("bytes")!!, call.method == "protectSecret")
                }
                "ownProcess" -> result.error("mobileRemoteOnly", "Local inference is unavailable on Android", null)
                else -> result.notImplemented()
            }
        }
        files.attach(engine.dartExecutor.binaryMessenger)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }

    /** Whole-file read of a picked document; exports embed it, so keep a sane ceiling. */
    private fun readDocument(uri: String): ByteArray {
        val target = android.net.Uri.parse(uri).buildUpon().fragment(null).build()
        val stream = context.contentResolver.openInputStream(target) ?: throw java.io.FileNotFoundException(uri)
        return stream.use { input ->
            val bytes = input.readBytes()
            check(bytes.size <= 256 * 1024 * 1024) { "fileTooLarge" }
            bytes
        }
    }

    fun async(result: MethodChannel.Result, operation: () -> Any?) {
        io.execute {
            try { val value = operation(); main.post { result.success(value) } }
            catch (error: Exception) { main.post { result.error(errorCode(error), error.message, null) } }
        }
    }
    /** A missing document or a message that is itself a string key becomes a localizable code. */
    private fun errorCode(error: Exception): String = when {
        error is java.io.FileNotFoundException -> "sourceFileMissing"
        error.message?.matches(Regex("[a-zA-Z]+")) == true -> error.message!!
        else -> "androidPlatform"
    }
    fun withActivity(result: MethodChannel.Result, operation: (MainActivity) -> Unit) {
        val foreground = activity.get()
        if (foreground == null || foreground.isFinishing) result.error("androidActivityRequired", "Open Altranscribe to grant permission", null)
        else operation(foreground)
    }
    fun startCapture(options: Map<String, Any?>, code: Int, data: Intent?, result: MethodChannel.Result) {
        if (startResult != null || audio.running) { result.error("busy", "Capture already running", null); return }
        captureOptions = options; projectionCode = code; projectionData = data; startResult = result
        try { context.startForegroundService(Intent(context, CaptureService::class.java).setAction("start")) }
        catch (error: Exception) { failStart(error) }
    }
    fun beginCapture() {
        val result = startResult ?: return
        startResult = null
        async(result) {
            try { audio.start(captureOptions, projectionCode, projectionData); null }
            catch (error: Exception) {
                main.post { context.stopService(Intent(context, CaptureService::class.java)) }
                throw error
            } finally { projectionData = null }
        }
    }
    fun failStart(error: Exception) {
        startResult?.error("androidCapture", error.message, null)
        startResult = null; projectionData = null
    }
    fun importFiles(paths: List<String>) {
        if (paths.isEmpty()) return
        pendingFiles = (pendingFiles + paths).distinct()
        platform.invokeMethod("importFiles", pendingFiles)
    }
    fun action(name: String) = platform.invokeMethod("sessionAction", name)

    private fun protect(bytes: ByteArray, encrypt: Boolean): ByteArray {
        require(bytes.size in 1..65536) { "Invalid credential" }
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "altranscribe.credentials"
        val key = (store.getKey(alias, null) as? SecretKey) ?: run {
            check(encrypt) { "Credential key unavailable" }
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            }.generateKey()
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        return if (encrypt) {
            cipher.init(Cipher.ENCRYPT_MODE, key)
            cipher.iv + cipher.doFinal(bytes)
        } else {
            require(bytes.size >= 28) { "Invalid encrypted credential" }
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.doFinal(bytes, 12, bytes.size - 12)
        }
    }
}
