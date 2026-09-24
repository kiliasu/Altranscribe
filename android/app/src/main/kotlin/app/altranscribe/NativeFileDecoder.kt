package app.altranscribe

import androidx.annotation.Keep

/** Bundled audio-only FFmpeg fallback for containers unsupported by Android. */
@Keep
class NativeFileDecoder : AutoCloseable {
    companion object { init { System.loadLibrary("altranscribe_media") } }
    @Volatile var cancelled = false
    private var pointer = 0L
    private external fun create(fd: Int): Long
    private external fun read(pointer: Long, limit: Int): ByteArray
    private external fun destroy(pointer: Long)
    fun isCancelled() = cancelled
    fun open(fd: Int) { pointer = create(fd) }
    fun read(limit: Int) = read(pointer, limit)
    override fun close() { if (pointer != 0L) destroy(pointer); pointer = 0 }
}
