package app.altranscribe

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Full-screen camera view that returns the first QR code it decodes. */
class ScanActivity : ComponentActivity() {
    companion object {
        const val EXTRA_HINT = "hint"
        const val EXTRA_TEXT = "text"
        const val EXTRA_DENIED = "denied"
        private const val PERMISSION_REQUEST = 1
    }
    private lateinit var preview: PreviewView
    private lateinit var analysis: ExecutorService
    private val reader = MultiFormatReader().apply {
        setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)))
    }
    @Volatile private var finished = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        analysis = Executors.newSingleThreadExecutor()
        preview = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        val density = resources.displayMetrics.density
        val hint = TextView(this).apply {
            text = intent.getStringExtra(EXTRA_HINT) ?: ""
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
            setBackgroundColor(0x99000000.toInt())
            val padding = (16 * density).toInt()
            setPadding(padding, padding, padding, padding + (24 * density).toInt())
        }
        val close = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setBackgroundColor(Color.TRANSPARENT)
            contentDescription = "Close"
            setOnClickListener { finish() }
        }
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(preview, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            addView(hint, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
            val size = (56 * density).toInt()
            addView(close, FrameLayout.LayoutParams(size, size, Gravity.TOP or Gravity.END).apply { topMargin = (32 * density).toInt(); marginEnd = (8 * density).toInt() })
        }
        setContentView(root)
        root.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) startCamera()
        else requestPermissions(arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startCamera()
        else { setResult(RESULT_CANCELED, Intent().putExtra(EXTRA_DENIED, true)); finish() }
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = future.get()
            val previewUse = Preview.Builder().build().also { it.surfaceProvider = preview.surfaceProvider }
            val analyzer = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(analysis) { image -> decode(image) } }
            try {
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, previewUse, analyzer)
            } catch (_: Exception) { finish() }
        }, ContextCompat.getMainExecutor(this))
    }

    /** ZXing reads the luminance plane directly; QR codes decode in any rotation. */
    private fun decode(image: ImageProxy) {
        try {
            if (finished) return
            val plane = image.planes[0]
            val buffer = plane.buffer
            val bytes = ByteArray(buffer.remaining()).also { buffer.get(it) }
            val source = PlanarYUVLuminanceSource(bytes, plane.rowStride, image.height, 0, 0, image.width, image.height, false)
            val text = try {
                reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
            } catch (_: NotFoundException) {
                null
            } finally {
                reader.reset()
            }
            if (text != null) {
                finished = true
                runOnUiThread {
                    setResult(RESULT_OK, Intent().putExtra(EXTRA_TEXT, text))
                    finish()
                }
            }
        } finally {
            image.close()
        }
    }

    override fun onDestroy() {
        analysis.shutdown()
        super.onDestroy()
    }
}
