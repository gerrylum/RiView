package org.dragonpilot.opview

// Record's "Camera + drive data" (design: claude/oprivview-telemetry-clips-design.md): the comma's
// camera as it arrives over WebRTC, without the overlay and without asking Android for the screen.
//
// A VideoSink on the stream's video track (found through flutter_webrtc by its id) gets each
// decoded frame. On a thread of our own, with an EGL context shared with WebRTC's, the frame is
// drawn into a texture of ours and from there into a MediaCodec H.264 encoder, as flutter_webrtc's
// own VideoFileRenderer does. Frames are let go of at once: holding one would stall the decoder,
// which has a single texture. The texture is drawn again now and then when no frame comes, so
// segments still get keyframes. From the encoder on it is the same as ScreenCapture: segment
// files, the buffer, clips joined without re-encoding (SegmentWriter, joinSegments).

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.opengl.GLES20
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.utils.EglUtils
import org.webrtc.EglBase
import org.webrtc.GlRectDrawer
import org.webrtc.GlTextureFrameBuffer
import org.webrtc.VideoFrame
import org.webrtc.VideoFrameDrawer
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.io.File
import java.util.concurrent.atomic.AtomicReference

private const val STAG = "RiViewRecordStream"

class StreamCapture(
    trackId: String,
    bufferMs: Long,
    private val segmentDir: File,
    private val clipDir: File,
    private val listener: CaptureListener,
) : Capture, VideoSink {
    private val thread = HandlerThread("RiViewRecordStream").apply { start() }
    private val gl = Handler(thread.looper)
    @Volatile private var running = false
    private var trackId = trackId
    private var track: VideoTrack? = null

    // the newest frame not yet drawn (older ones are dropped, never queued)
    private val pending = AtomicReference<VideoFrame?>(null)

    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var egl: EglBase? = null
    private var drawer: GlRectDrawer? = null
    private var frameDrawer: VideoFrameDrawer? = null
    private var copy: GlTextureFrameBuffer? = null
    private var drainThread: Thread? = null
    private var outW = 0
    private var outH = 0
    private var failed = false

    private var haveFrame = false
    private var lastPtsNs = 0L
    private var lastDrawWallNs = 0L
    private val identity = FloatArray(16).also { android.opengl.Matrix.setIdentityM(it, 0) }

    private val segments = SegmentWriter(segmentDir).apply { setBuffer(bufferMs * 1000) }

    override var bufferMs: Long = bufferMs
        set(value) {
            field = value
            segments.setBuffer(value * 1000)
        }

    override val recording: Boolean get() = segments.recording

    // no frames (the car stopped sending, a reconnect): the last one again, so segments go on
    private val keepAlive = object : Runnable {
        override fun run() {
            if (!running) return
            try {
                val now = System.nanoTime()
                if (haveFrame && now - lastDrawWallNs >= KEEP_ALIVE_MS * 1_000_000) {
                    present(lastPtsNs + (now - lastDrawWallNs))
                }
            } catch (e: Exception) {
                Log.w(STAG, "keep alive", e)
            }
            gl.postDelayed(this, KEEP_ALIVE_MS)
        }
    }

    override fun start() {
        segmentDir.mkdirs()
        segmentDir.listFiles()?.forEach { it.delete() }  // left over from a crash
        clipDir.mkdirs()
        running = true
        gl.post { attach(trackId) }
        gl.postDelayed(keepAlive, KEEP_ALIVE_MS)
    }

    /** the stream's video track is a new one (a reconnect, the other camera) */
    fun setTrack(id: String) {
        gl.post { if (running) attach(id) }
    }

    override fun stop() {
        running = false
        segments.abandonClip()
        gl.post {
            detach()
            pending.getAndSet(null)?.release()
            try {
                encoder?.signalEndOfInputStream()
            } catch (e: Exception) {
                Log.w(STAG, "stop", e)
            }
        }
        gl.post {
            drainThread?.join(2000)
            try {
                encoder?.stop()
                encoder?.release()
            } catch (e: Exception) {
                Log.w(STAG, "release encoder", e)
            }
            try {
                copy?.release()
                drawer?.release()
                frameDrawer?.release()
                egl?.release()
                inputSurface?.release()
            } catch (e: Exception) {
                Log.w(STAG, "release gl", e)
            }
            segments.closeAll()
            segmentDir.listFiles()?.forEach { it.delete() }
            thread.quitSafely()
        }
    }

    // the stream is recorded whatever the screen shows: nothing to crop or pause
    override fun setCrop(rect: CropRect) {}

    override fun setPaused(value: Boolean, reason: String) {}

    override fun startClip(): Long = segments.startClip(bufferMs * 1000) / 1000

    override fun stopClip() {
        segments.requestStop()
        try {
            encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (e: Exception) {
            Log.w(STAG, "keyframe", e)
        }
    }

    // -- the track --

    private fun attach(id: String) {
        detach()
        trackId = id
        val t = try {
            FlutterWebRTCPlugin.sharedSingleton?.getRemoteTrack(id) as? VideoTrack
        } catch (e: Exception) {
            Log.w(STAG, "find track", e)
            null
        }
        if (t == null) {
            Log.w(STAG, "no video track $id")
            return
        }
        try {
            t.addSink(this)
            track = t
        } catch (e: Exception) {
            Log.w(STAG, "add sink", e)
        }
    }

    private fun detach() {
        val t = track ?: return
        track = null
        try {
            t.removeSink(this)
        } catch (e: Exception) {
            // the track was already disposed with its connection
        }
    }

    // -- each frame (WebRTC's decoder thread) --

    override fun onFrame(frame: VideoFrame) {
        if (!running || failed) return
        frame.retain()
        val older = pending.getAndSet(frame)
        if (older != null) {
            older.release()  // not drawn yet: this one replaces it, and a draw is already posted
        } else {
            gl.post { drawPending() }
        }
    }

    private fun drawPending() {
        val frame = pending.getAndSet(null) ?: return
        try {
            if (!running) return
            if (encoder == null && !setUp(frame.rotatedWidth, frame.rotatedHeight)) return
            val fbo = copy ?: return
            // into our own texture, so the frame can go back to the decoder straight away
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo.frameBufferId)
            GLES20.glViewport(0, 0, outW, outH)
            frameDrawer?.drawFrame(frame, drawer!!, null, 0, 0, outW, outH)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            haveFrame = true
            present(System.nanoTime())
        } catch (e: Exception) {
            Log.w(STAG, "frame", e)
        } finally {
            frame.release()
        }
    }

    /** our copy of the newest frame into the encoder at [ptsNs], kept strictly after the last one */
    private fun present(ptsNs: Long) {
        val e = egl ?: return
        val fbo = copy ?: return
        val pts = maxOf(ptsNs, lastPtsNs + 1_000_000)  // at least 1 ms on
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glViewport(0, 0, outW, outH)
        drawer?.drawRgb(fbo.textureId, identity, outW, outH, 0, 0, outW, outH)
        e.swapBuffers(pts)
        lastPtsNs = pts
        lastDrawWallNs = System.nanoTime()
    }

    // -- set up, at the first frame (its size is the video's) --

    private fun setUp(frameW: Int, frameH: Int): Boolean {
        try {
            val scale = minOf(1.0, MAX_WIDTH.toDouble() / frameW)
            outW = ((frameW * scale).toInt() / 2) * 2
            outH = ((frameH * scale).toInt() / 2) * 2
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, KEYFRAME_S)
                setInteger("max-bframes", 0)  // frame times only go forward (see ScreenCapture)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = enc.createInputSurface()
            enc.start()
            encoder = enc
            inputSurface = surface

            val e = EglBase.create(EglUtils.getRootEglBaseContext(), EglBase.CONFIG_RECORDABLE)
            e.createSurface(surface)
            e.makeCurrent()
            egl = e
            drawer = GlRectDrawer()
            frameDrawer = VideoFrameDrawer()
            copy = GlTextureFrameBuffer(GLES20.GL_RGBA).apply { setSize(outW, outH) }

            drainThread = Thread({ drain(enc) }, "RiViewRecordStreamDrain").apply { start() }
            Log.i(STAG, "recording the stream at ${outW}x$outH")
            return true
        } catch (e: Exception) {
            Log.e(STAG, "set up", e)
            failed = true
            listener.onClipFailed("Could not record the camera: ${e.message}")
            return false
        }
    }

    // -- encoder output (as ScreenCapture) --

    private fun drain(enc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = try {
                enc.dequeueOutputBuffer(info, 50_000)
            } catch (e: Exception) {
                break
            }
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> segments.format = enc.outputFormat
                index >= 0 -> {
                    val buf = enc.getOutputBuffer(index)
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (buf != null && !config && info.size > 0) {
                        val done = segments.write(buf, info)
                        if (done != null) joinClip(done)
                    }
                    enc.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
                !running && index == MediaCodec.INFO_TRY_AGAIN_LATER -> break
            }
        }
    }

    private fun joinClip(clip: FinishedClip) {
        Thread({
            try {
                val out = File(clipDir, "${clip.startWallMs}.mp4")
                val durationUs = joinSegments(clip.files, clip.startsUs, out)
                writeThumbnail(out, File(clipDir, "${clip.startWallMs}.jpg"))
                listener.onClipSaved(out.absolutePath, clip.startWallMs, durationUs / 1000, clip.bufferedUs / 1000)
            } catch (e: Exception) {
                Log.e(STAG, "join", e)
                listener.onClipFailed("Could not save the clip: ${e.message}")
            } finally {
                segments.release(clip.files)
            }
        }, "RiViewRecordStreamJoin").start()
    }
}
