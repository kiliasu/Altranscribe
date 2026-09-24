package app.altranscribe

import android.content.Context
import android.content.Intent
import android.media.*
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

/** Independent AudioRecord instances; PCM is kept in bounded memory only. */
class AudioCapture(private val context: Context) {
    private val events = ArrayDeque<Map<String, Any>>()
    private val sources = mutableListOf<Source>()
    private var projection: MediaProjection? = null
    @Volatile private var stopping = false
    private var origin = 0L
    val running get() = sources.isNotEmpty()

    fun devices(): List<Map<String, String>> {
        val audio = context.getSystemService(AudioManager::class.java)
        return audio.getDevices(AudioManager.GET_DEVICES_INPUTS).map {
            mapOf("id" to it.id.toString(), "name" to it.productName.toString(), "source" to "microphone")
        }
    }

    @Synchronized fun poll(): List<Map<String, Any>> = events.toList().also { events.clear() }
    @Synchronized private fun emit(event: Map<String, Any>) {
        if (events.size >= 256) {
            events.removeAll { it["type"] == "level" || it["partial"] == true }
            if (events.size >= 256) {
                if (events.none { it["type"] == "error" }) {
                    events.add(mapOf("type" to "error", "source" to "system", "message" to "audioGap"))
                }
                stopping = true
                return
            }
        }
        events.add(event)
    }

    fun start(options: Map<String, Any?>, resultCode: Int, projectionData: Intent?) {
        check(!running) { "Capture already running" }
        check(options["microphone"] == true || options["system"] == true) { "No audio source selected" }
        poll()
        stopping = false
        origin = SystemClock.elapsedRealtime()
        try {
            if (options["system"] == true) {
                check(projectionData != null) { "System audio permission required" }
                projection = context.getSystemService(MediaProjectionManager::class.java)
                    .getMediaProjection(resultCode, projectionData)
                projection!!.registerCallback(object : MediaProjection.Callback() {
                    override fun onStop() {
                        if (!stopping) {
                            emit(mapOf("type" to "error", "source" to "system", "message" to "androidCaptureRevoked"))
                            stopping = true
                        }
                    }
                }, Handler(Looper.getMainLooper()))
            }
            for (name in listOf("microphone", "system")) {
                if (options[name] == true) sources.add(Source(name, options).also { it.start() })
            }
        } catch (error: Exception) {
            stop()
            throw error
        }
    }

    fun pause(paused: Boolean) { sources.forEach { it.setPaused(paused) } }
    fun stop(): List<Map<String, Any>> {
        stopping = true
        sources.forEach { it.join(5000) }
        sources.clear()
        projection?.stop()
        projection = null
        return poll()
    }

    private inner class Source(private val name: String, private val options: Map<String, Any?>) : Thread("Altranscribe-$name") {
        private val commands = LinkedBlockingQueue<Pair<Boolean, CountDownLatch>>()
        private var paused = false
        private val rate = (options["sampleRate"] as? Number)?.toInt() ?: 16000
        private val streaming = options["streaming"] == true
        private var offset = 0L
        private var sampleCount = 0L
        private var frameStart = 0L
        private val stream = ByteArrayOutputStream()
        private lateinit var chunker: NativeChunker
        private fun now() = SystemClock.elapsedRealtime() - origin
        private fun send(type: String, values: Map<String, Any> = emptyMap()) =
            emit(mapOf("type" to type, "source" to name) + values)

        fun setPaused(value: Boolean) {
            val done = CountDownLatch(1)
            commands.add(value to done)
            check(done.await(5, TimeUnit.SECONDS) && isAlive) { "Audio pause failed" }
        }

        private fun flushStream() {
            if (stream.size() == 0) return
            send("frame", mapOf("pcm" to stream.toByteArray(), "startMs" to frameStart,
                "endMs" to offset + sampleCount * 1000 / rate))
            stream.reset()
            frameStart = offset + sampleCount * 1000 / rate
        }

        override fun run() {
            var recorder: AudioRecord? = null
            var dsp: NativeDsp? = null
            try {
                check(rate == 16000 || rate == 24000) { "Unsupported output rate" }
                val inputRate = 48000
                val format = AudioFormat.Builder().setSampleRate(inputRate)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
                val builder = AudioRecord.Builder().setAudioFormat(format).setBufferSizeInBytes(
                    maxOf(inputRate / 2, AudioRecord.getMinBufferSize(inputRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)))
                if (name == "system") {
                    builder.setAudioPlaybackCaptureConfig(AudioPlaybackCaptureConfiguration.Builder(projection!!)
                        .addMatchingUsage(AudioAttributes.USAGE_MEDIA).addMatchingUsage(AudioAttributes.USAGE_GAME)
                        .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN).build())
                } else builder.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                recorder = builder.build()
                check(recorder.state == AudioRecord.STATE_INITIALIZED) { "Audio device initialization failed" }
                val selected = options["${name}Device"] as? String ?: ""
                if (name == "microphone" && selected.isNotEmpty()) {
                    val device = context.getSystemService(AudioManager::class.java)
                        .getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id.toString() == selected }
                    check(device != null && recorder.setPreferredDevice(device)) { "deviceUnavailable" }
                }
                chunker = NativeChunker(rate) { pcm, from, to, partial, continues ->
                    send("chunk", mapOf("pcm" to pcm, "startMs" to from, "endMs" to to,
                        "partial" to partial, "continues" to continues))
                }
                dsp = NativeDsp(inputRate, rate, options["${name}Denoise"] == true,
                    options["${name}AutoGain"] == true, File(context.filesDir, "rnnoise-model.bin").path) { pcm, speech ->
                    sampleCount += pcm.size / 2
                    if (streaming) {
                        stream.write(pcm)
                        if (stream.size() >= rate / 5) flushStream()
                    } else chunker.add(pcm, speech)
                }
                fun reset() {
                    offset = now(); frameStart = offset; sampleCount = 0
                    dsp.reset(); chunker.reset(offset)
                }
                fun flush() { dsp.finish(); if (streaming) flushStream() else chunker.finish() }
                reset()
                recorder.startRecording()
                check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Audio capture could not start" }
                send("ready")
                var levelAt = now()
                var energy = 0.0
                var levelSamples = 0
                val samples = ShortArray(4800)
                while (!stopping) {
                    var command = commands.poll()
                    while (command != null) {
                        try {
                            if (command.first != paused) {
                                if (command.first) {
                                    recorder.stop(); flush()
                                    send("paused", mapOf("endMs" to offset + sampleCount * 1000 / rate))
                                } else { reset(); recorder.startRecording() }
                                paused = command.first
                            }
                        } finally { command.second.countDown() }
                        command = commands.poll()
                    }
                    if (paused) { sleep(10); continue }
                    val count = recorder.read(samples, 0, samples.size, AudioRecord.READ_NON_BLOCKING)
                    check(count >= 0) { "Audio device disconnected ($count)" }
                    if (count == 0) { sleep(5); continue }
                    val floats = FloatArray(count) { samples[it] / 32768f }
                    for (sample in floats) energy += sample * sample
                    levelSamples += count
                    dsp.process(floats)
                    if (now() - levelAt >= 200) {
                        send("level", mapOf("level" to (sqrt(energy / maxOf(1, levelSamples)) * 4).coerceIn(0.0, 1.0)))
                        energy = 0.0; levelSamples = 0; levelAt = now()
                    }
                }
                if (!paused) { recorder.stop(); flush() }
            } catch (error: Exception) {
                if (!stopping) send("error", mapOf("message" to (error.message ?: "Audio capture failed")))
            } finally {
                recorder?.release()
                dsp?.close()
                if (::chunker.isInitialized) chunker.close()
                for (command in commands) command.second.countDown()
            }
        }
    }
}
