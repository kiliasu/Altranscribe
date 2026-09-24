package app.altranscribe

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/** Pull decoder: one PCM window plus codec buffers, without copying source media. */
class AudioFileReader(private val context: Context) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var cancelled = false
    @Volatile private var fallback: NativeFileDecoder? = null
    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var dsp: NativeDsp? = null
    private var format: MediaFormat? = null
    private var raw = false
    private var inputDone = false
    private var outputDone = false
    private var chunks = ByteArrayOutputStream()
    private var chunkBytes = 640000
    private var samples = 0L

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, "altranscribe/files").setMethodCallHandler { call, result ->
            if (call.method == "cancel") { cancelled = true; fallback?.cancelled = true }
            worker.execute {
                try {
                    val value = when (call.method) {
                        "open" -> { open(call.argument<String>("path")!!, call.argument<Int>("chunkSeconds") ?: 20); null }
                        "next" -> next()
                        "close", "cancel" -> { close(); null }
                        else -> throw IllegalArgumentException("Unknown file operation")
                    }
                    main.post { result.success(value) }
                } catch (error: Exception) {
                    close()
                    main.post { result.error("androidFileDecode", error.message, null) }
                }
            }
        }
    }
    private fun open(path: String, seconds: Int) {
        close(); cancelled = false
        require(seconds in 1..600) { "Invalid audio window" }
        chunkBytes = seconds * 32000; samples = 0
        inputDone = false; outputDone = false; chunks.reset()
        try { openPlatform(path) }
        catch (_: Exception) {
            // WMA/ASF and some codec variants have no Android system decoder.
            close()
            if (cancelled) return
            val uri = Uri.parse(path).buildUpon().fragment(null).build()
            val descriptor = if (uri.scheme == "content") context.contentResolver.openFileDescriptor(uri, "r")
                else ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
            requireNotNull(descriptor) { "Cannot open audio document" }
            descriptor.use { file ->
                val decoder = NativeFileDecoder()
                fallback = decoder
                decoder.cancelled = cancelled
                decoder.open(file.fd)
            }
        }
    }
    private fun openPlatform(path: String) {
        val reader = MediaExtractor(); extractor = reader
        val uri = Uri.parse(path).buildUpon().fragment(null).build()
        if (uri.scheme == "content") reader.setDataSource(context, uri, null) else reader.setDataSource(path)
        val index = (0 until reader.trackCount).firstOrNull { reader.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            ?: throw IllegalArgumentException("No audio track in this file")
        reader.selectTrack(index)
        format = reader.getTrackFormat(index)
        val mime = format!!.getString(MediaFormat.KEY_MIME)!!
        raw = mime == "audio/raw"
        if (raw) configure(format!!)
        else codec = MediaCodec.createDecoderByType(mime).also { it.configure(format, null, null, 0); it.start() }
    }
    private fun configure(value: MediaFormat) {
        dsp?.finish(); dsp?.close()
        format = value
        dsp = NativeDsp(value.getInteger(MediaFormat.KEY_SAMPLE_RATE), 16000, false, false,
            File(context.filesDir, "rnnoise-model.bin").path) { pcm, _ -> chunks.write(pcm) }
    }
    private fun pcm(buffer: ByteBuffer) {
        val audio = format!!
        val channels = audio.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val encoding = if (audio.containsKey(MediaFormat.KEY_PCM_ENCODING)) audio.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
        val bytes = when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_32BIT -> 4
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
            AudioFormat.ENCODING_PCM_8BIT -> 1
            AudioFormat.ENCODING_PCM_16BIT -> 2
            else -> throw IllegalArgumentException("Unsupported PCM encoding")
        }
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        val mono = FloatArray(buffer.remaining() / (bytes * channels)) {
            var sum = 0f
            repeat(channels) {
                sum += when (encoding) {
                    AudioFormat.ENCODING_PCM_FLOAT -> buffer.float
                    AudioFormat.ENCODING_PCM_32BIT -> (buffer.int / 2147483648.0).toFloat()
                    AudioFormat.ENCODING_PCM_24BIT_PACKED -> {
                        val value = (buffer.get().toInt() and 255) or ((buffer.get().toInt() and 255) shl 8) or (buffer.get().toInt() shl 16)
                        value / 8388608f
                    }
                    AudioFormat.ENCODING_PCM_8BIT -> ((buffer.get().toInt() and 255) - 128) / 128f
                    else -> buffer.short / 32768f
                }
            }
            sum / channels
        }
        dsp!!.process(mono)
    }
    private fun next(): Map<String, Any>? {
        fallback?.let { decoder ->
            val pcm = decoder.read(chunkBytes)
            if (cancelled || pcm.isEmpty()) return null
            val from = samples * 1000 / 16000
            samples += pcm.size / 2
            return mapOf("pcm" to pcm, "startMs" to from, "endMs" to samples * 1000 / 16000)
        }
        if (cancelled) return null
        check(extractor != null) { "No open audio file" }
        val reader = extractor!!
        val info = MediaCodec.BufferInfo()
        var lastProgress = SystemClock.elapsedRealtime()
        while (chunks.size() < chunkBytes && !outputDone && !cancelled) {
            if (raw) {
                val buffer = ByteBuffer.allocate(65536)
                val count = reader.readSampleData(buffer, 0)
                if (count < 0) outputDone = true else { buffer.position(0); buffer.limit(count); pcm(buffer); reader.advance() }
            } else {
                val decoder = codec!!
                if (!inputDone) {
                    val index = decoder.dequeueInputBuffer(10000)
                    if (index >= 0) {
                        val buffer = decoder.getInputBuffer(index)!!
                        val count = reader.readSampleData(buffer, 0)
                        if (count < 0) { inputDone = true; decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM) }
                        else { decoder.queueInputBuffer(index, 0, count, reader.sampleTime, 0); reader.advance() }
                    }
                }
                val index = decoder.dequeueOutputBuffer(info, 10000)
                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> configure(decoder.outputFormat)
                    index >= 0 -> {
                        try {
                            if (info.size > 0) {
                                if (dsp == null) configure(decoder.outputFormat)
                                val buffer = decoder.getOutputBuffer(index)!!
                                buffer.position(info.offset); buffer.limit(info.offset + info.size); pcm(buffer)
                            }
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                            lastProgress = SystemClock.elapsedRealtime()
                        } finally { decoder.releaseOutputBuffer(index, false) }
                    }
                }
                check(SystemClock.elapsedRealtime() - lastProgress < 30000) { "Audio decoder stalled" }
            }
            if (outputDone) dsp?.finish()
        }
        if (cancelled || chunks.size() == 0) return null
        val bytes = chunks.toByteArray()
        val count = minOf(chunkBytes, bytes.size)
        chunks.reset(); chunks.write(bytes, count, bytes.size - count)
        val start = samples * 1000 / 16000
        samples += count / 2
        return mapOf("pcm" to bytes.copyOf(count), "startMs" to start, "endMs" to samples * 1000 / 16000)
    }
    private fun close() {
        dsp?.close(); dsp = null
        try { codec?.stop() } catch (_: IllegalStateException) { }
        codec?.release(); codec = null
        extractor?.release(); extractor = null
        fallback?.close(); fallback = null
        chunks.reset()
    }
}
