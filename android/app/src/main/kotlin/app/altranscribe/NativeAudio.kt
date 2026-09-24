package app.altranscribe

import androidx.annotation.Keep

/** Audio preprocessing only. There is no on-device Whisper or LLM engine. */
@Keep
class NativeDsp(input: Int, output: Int, denoise: Boolean, gain: Boolean,
                model: String, private val outputFrame: (ByteArray, Boolean) -> Unit) : AutoCloseable {
    companion object { init { System.loadLibrary("altranscribe_audio") } }
    private var pointer = create(input, output, denoise, gain, model)
    private external fun create(input: Int, output: Int, denoise: Boolean, gain: Boolean, model: String): Long
    private external fun process(pointer: Long, input: FloatArray)
    private external fun finish(pointer: Long)
    private external fun reset(pointer: Long)
    private external fun destroy(pointer: Long)
    fun onFrame(pcm: ByteArray, speech: Boolean) = outputFrame(pcm, speech)
    fun process(input: FloatArray) = process(pointer, input)
    fun finish() = finish(pointer)
    fun reset() = reset(pointer)
    override fun close() { if (pointer != 0L) destroy(pointer); pointer = 0 }
}

@Keep
class NativeChunker(rate: Int, private val output: (ByteArray, Long, Long, Boolean, Boolean) -> Unit) : AutoCloseable {
    companion object { init { System.loadLibrary("altranscribe_audio") } }
    private var pointer = create(rate)
    private external fun create(rate: Int): Long
    private external fun add(pointer: Long, pcm: ByteArray, speech: Boolean)
    private external fun finish(pointer: Long)
    private external fun reset(pointer: Long, start: Long)
    private external fun destroy(pointer: Long)
    fun onChunk(pcm: ByteArray, start: Long, end: Long, partial: Boolean, continues: Boolean) =
        output(pcm, start, end, partial, continues)
    fun add(pcm: ByteArray, speech: Boolean) = add(pointer, pcm, speech)
    fun finish() = finish(pointer)
    fun reset(start: Long) = reset(pointer, start)
    override fun close() { if (pointer != 0L) destroy(pointer); pointer = 0 }
}
