// HollerShare's own Android source: the phone camera behind "Use as
// webcam" (src/camera/camera_android.zig calls it as the Oriel extension
// "hollershare.camera"; build.zig declares it). The network side is Zig.
package dev.hollershare

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.OrientationEventListener
import android.view.Window
import android.view.WindowManager
import androidx.annotation.Keep
import dev.oriel.OrielAppExtension
import dev.oriel.OrielCall
import dev.oriel.OrielExtensionError
import dev.oriel.OrielRuntime
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Methods (input and reply are JSON, except `frame`):
 * - `permission`: asks for the camera permission if needed; `{"granted":bool}`.
 * - `start` `{"facing":"back","height":720,"fps":30,"jpeg":70}`: opens the
 *   camera; `{"width":1280,"height":720}`. The size is one both cameras
 *   have near `height` (16:9), so switching keeps it.
 * - `quality` `{"fps":24,"jpeg":85}`: a new frame rate and JPEG quality.
 * - `frame`: the newest frame as JPEG bytes, waiting up to a second for one
 *   (empty: none came). Fails with `camera_lost` once the camera is gone.
 * - `switch`: the other camera, same size. `stop`: closes it.
 * - `view` `{"rotate":90,"mirror":false,"fill":false}`: turn the picture
 *   further clockwise, mirror it, and fill the frame (cropped) rather than
 *   fit it (black bars) when it is portrait.
 *
 * Frames are upright however the phone is held (its motion sensor, not
 * the screen, which may not turn), and always the same landscape size:
 * a video app keeps the size it opened the camera with.
 */
@Keep
class CameraExtension : OrielAppExtension {
    private companion object {
        const val TAG = "HollerShare"
        /** A request code Oriel's permission handler ignores. */
        const val REQUEST_CODE = 0x4F2D
        const val OPEN_TIMEOUT_S = 8L
    }

    private val lock = ReentrantLock()
    private val arrived = lock.newCondition()
    private var latest: ByteArray? = null
    private var produced = 0L
    private var delivered = 0L
    private var lost: String? = null

    // Lifecycle calls hold this lock. Camera and UI callbacks never take it.
    private val lifecycleLock = ReentrantLock()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var generation = 0L
    private var terminating = false
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var size: Size? = null
    private var orientation: OrientationEventListener? = null
    private var screenWindow: Window? = null

    // Set up before callbacks run, then owned by the worker until it has drained.
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var repeatCapture: ((Int) -> Unit)? = null
    private var facing = CameraCharacteristics.LENS_FACING_BACK
    private var sensorOrientation = 90
    private var nv21: ByteArray? = null
    private var turned: ByteArray? = null
    /** One chroma row each, reused by `encode` (camera thread). */
    private var uRowBuf: ByteArray? = null
    private var vRowBuf: ByteArray? = null

    /** How the phone is turned clockwise from upright: 0, 90, 180 or 270. */
    @Volatile private var deviceDegrees = 0
    @Volatile private var extraRotation = 0
    @Volatile private var mirror = false
    @Volatile private var fill = false
    @Volatile private var fps = 30
    @Volatile private var jpegQuality = 70
    /** When the last frame was encoded (camera thread), for the frame rate. */
    private var lastFrameNs = 0L

    private val manager: CameraManager
        get() = OrielRuntime.app.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    override fun call(method: String, input: ByteArray, call: OrielCall): ByteArray = when (method) {
        "permission" -> reply(JSONObject().put("granted", ensurePermission(call)))
        "start" -> {
            val json = if (input.isEmpty()) JSONObject() else JSONObject(String(input))
            val height = json.optInt("height", 720).coerceIn(240, 2160)
            val front = json.optString("facing", "back") == "front"
            start(if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK, height, json, call)
        }
        "quality" -> lifecycleLock.withLock {
            setQuality(if (input.isEmpty()) JSONObject() else JSONObject(String(input)))
            reply(JSONObject())
        }
        "frame" -> frame(call)
        "switch" -> lifecycleLock.withLock {
            val s = size ?: throw OrielExtensionError("not_started", "The camera isn't on")
            val other = if (facing == CameraCharacteristics.LENS_FACING_BACK) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
            stopCapture()
            try {
                startCapture(other, s, call)
                reply(JSONObject().put("facing", if (other == CameraCharacteristics.LENS_FACING_FRONT) "front" else "back"))
            } catch (t: Throwable) {
                stop()
                gone(t.message ?: "The camera couldn't switch")
                throw t
            }
        }
        "view" -> {
            val json = if (input.isEmpty()) JSONObject() else JSONObject(String(input))
            extraRotation = ((json.optInt("rotate", 0) % 360 + 360) % 360) / 90 * 90
            mirror = json.optBoolean("mirror", false)
            fill = json.optBoolean("fill", false)
            reply(JSONObject())
        }
        "stop" -> lifecycleLock.withLock {
            stop()
            reply(JSONObject())
        }
        else -> throw OrielExtensionError("unknown_method", "No method $method")
    }

    override fun onLifecycle(event: String, level: String?) {
        if (event == "terminating") lifecycleLock.withLock {
            terminating = true
            stop()
        }
    }

    private fun reply(json: JSONObject) = json.toString().toByteArray()

    private fun granted() = OrielRuntime.app.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    /** Ask once (on the Activity in front), then wait up to a minute for the answer. */
    private fun ensurePermission(call: OrielCall): Boolean {
        if (granted()) return true
        val host = OrielRuntime.foreground ?: return false
        host.runOnUiThread { host.requestPermissions(arrayOf(Manifest.permission.CAMERA), REQUEST_CODE) }
        repeat(600) {
            if (granted()) return true
            if (call.isCancelled) return false
            Thread.sleep(100)
        }
        return granted()
    }

    private fun setQuality(json: JSONObject) {
        val wanted = json.optInt("fps", fps).coerceIn(5, 30)
        jpegQuality = json.optInt("jpeg", jpegQuality).coerceIn(30, 95)
        if (wanted == fps) return
        fps = wanted
        val attempt = generation
        handler?.post {
            if (attempt != generation || wanted != fps) return@post
            try {
                repeatCapture?.invoke(wanted)
            } catch (e: Exception) {
                Log.w(TAG, "Couldn't update the capture frame rate", e)
            }
        }
    }

    private fun start(wanted: Int, height: Int, json: JSONObject, call: OrielCall): ByteArray {
        // Permission can require the UI thread. Stop can retire a pending prompt.
        val beforePermission = generation
        val needsPermission = !granted()
        if (needsPermission && !ensurePermission(call)) throw OrielExtensionError("permission_denied", "HollerShare may not use the camera")
        return lifecycleLock.withLock {
            if (terminating || call.isCancelled || (needsPermission && beforePermission != generation)) {
                throw OrielExtensionError("camera_failed", "The camera start was cancelled")
            }
            stop()
            try {
                setQuality(json)
                val s = chooseSize(height)
                startCapture(wanted, s, call)
                watchOrientation(true)
                keepScreenOn(true)
                reply(JSONObject().put("width", s.width).put("height", s.height))
            } catch (t: Throwable) {
                stop()
                throw t
            }
        }
    }

    private fun startCapture(wanted: Int, s: Size, call: OrielCall) {
        lock.withLock { lost = null }
        lastFrameNs = 0L
        val t = HandlerThread("HollerShare camera")
        thread = t
        t.start()
        handler = Handler(t.looper)
        open(wanted, s)
        if (call.isCancelled) throw OrielExtensionError("camera_failed", "The camera start was cancelled")
        size = s
    }

    private fun stop() {
        try {
            stopCapture()
        } finally {
            try { watchOrientation(false) } finally { keepScreenOn(false) }
        }
    }

    private fun stopCapture() {
        generation++
        thread?.let { t ->
            handler?.post { closeNow() }
            t.quitSafely()
            // A cancelled caller still has to finish teardown before another start.
            var interrupted = false
            while (t.isAlive) {
                try { t.join() } catch (_: InterruptedException) { interrupted = true }
            }
            if (interrupted) Thread.currentThread().interrupt()
        }
        // If the worker had already exited, any resources it left are safe to close here.
        closeNow()
        thread = null
        handler = null
        size = null
        nv21 = null
        turned = null
        uRowBuf = null
        vRowBuf = null
        lock.withLock {
            latest = null
            produced = 0
            delivered = 0
            arrived.signalAll()
        }
    }

    private fun frame(call: OrielCall): ByteArray = lock.withLock {
        var waited = 0L
        while (produced == delivered && lost == null) {
            if (call.isCancelled || waited >= 1000) return ByteArray(0)
            arrived.await(100, TimeUnit.MILLISECONDS)
            waited += 100
        }
        lost?.let { throw OrielExtensionError("camera_lost", it) }
        delivered = produced
        latest ?: ByteArray(0)
    }

    /** The first camera facing `wanted`. */
    private fun cameraId(wanted: Int): String? = manager.cameraIdList.firstOrNull {
        manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == wanted
    } ?: manager.cameraIdList.firstOrNull()

    /** A YUV size the front and back cameras share: 16:9 at `height`, else the biggest 16:9 below it, else the biggest below it. */
    private fun chooseSize(height: Int): Size {
        val sets = listOf(CameraCharacteristics.LENS_FACING_BACK, CameraCharacteristics.LENS_FACING_FRONT).mapNotNull { f ->
            val id = manager.cameraIdList.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == f } ?: return@mapNotNull null
            manager.getCameraCharacteristics(id).get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(ImageFormat.YUV_420_888)?.toSet()
        }
        if (sets.isEmpty()) throw OrielExtensionError("no_camera", "This phone has no camera HollerShare can use")
        val common = sets.reduce { a, b -> a intersect b }.ifEmpty { sets.first() }
        // 16:9 within a few pixels: 480 lines is 854 wide (853.3 exactly).
        fun wide(s: Size) = Math.abs(s.width * 9 - s.height * 16) <= 16
        val width = (height * 16 + 8) / 9
        val limit = width * height
        common.firstOrNull { it.height == height && wide(it) }?.let { return it }
        val fitting = common.filter { it.width * it.height <= limit }
        return fitting.filter { wide(it) }.maxByOrNull { it.width * it.height }
            ?: fitting.maxByOrNull { it.width * it.height }
            ?: common.minBy { it.width * it.height }
    }

    /** Open the camera facing `wanted` into an ImageReader of `s`, and wait until frames flow. */
    private fun open(wanted: Int, s: Size) {
        val h = handler ?: throw OrielExtensionError("not_started", "The camera isn't on")
        val id = cameraId(wanted) ?: throw OrielExtensionError("no_camera", "This phone has no camera HollerShare can use")
        val characteristics = manager.getCameraCharacteristics(id)
        facing = characteristics.get(CameraCharacteristics.LENS_FACING) ?: wanted
        sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val attempt = generation
        fun currentAttempt() = attempt == generation && Thread.currentThread() === h.looper.thread
        // Keep delivering Camera2 callbacks after the worker quits so late resources can be closed.
        val callbacks = Executor { task ->
            if (attempt == generation && h.post(task)) return@Executor
            if (!mainHandler.post(task)) task.run()
        }
        val imageReader = ImageReader.newInstance(s.width, s.height, ImageFormat.YUV_420_888, 3)
        reader = imageReader
        imageReader.setOnImageAvailableListener({ r ->
            if (attempt != generation) return@setOnImageAvailableListener
            val image = try { r.acquireLatestImage() } catch (_: IllegalStateException) { null } ?: return@setOnImageAvailableListener
            try {
                // Fewer frames than the camera's: skip encoding until the next is due.
                val now = System.nanoTime()
                val due = 1_000_000_000L / fps - 4_000_000L
                if (now - lastFrameNs < due) return@setOnImageAvailableListener
                lastFrameNs = now
                publish(encode(image))
            } catch (t: Throwable) {
                Log.w(TAG, "camera frame: ${t.message}")
            } finally {
                image.close()
            }
        }, h)

        val ready = CountDownLatch(1)
        val problem = AtomicReference<String?>()
        fun failed(why: String) {
            problem.compareAndSet(null, why)
            ready.countDown()
        }

        val capture = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(configured: CameraCaptureSession) {
                if (!currentAttempt() || problem.get() != null) {
                    configured.close()
                    return
                }
                val camera = device
                if (camera == null) {
                    configured.close()
                    failed("the camera closed before capture was ready")
                    return
                }
                session = configured
                try {
                    val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                        addTarget(imageReader.surface)
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                    }
                    val submit: (Int) -> Unit = { wantedFps ->
                        request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange(characteristics, wantedFps))
                        configured.setRepeatingRequest(request.build(), null, h)
                    }
                    submit(fps)
                    repeatCapture = submit
                    ready.countDown()
                } catch (t: Throwable) {
                    failed(t.message ?: "the camera refused the request")
                }
            }

            override fun onConfigureFailed(configured: CameraCaptureSession) {
                configured.close()
                if (currentAttempt()) failed("the camera couldn't be configured")
            }
        }

        try {
            manager.openCamera(id, callbacks, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (!currentAttempt() || problem.get() != null) {
                        camera.close()
                        return
                    }
                    device = camera
                    try {
                        camera.createCaptureSession(SessionConfiguration(
                            SessionConfiguration.SESSION_REGULAR,
                            listOf(OutputConfiguration(imageReader.surface)),
                            callbacks,
                            capture
                        ))
                    } catch (t: Throwable) {
                        failed(t.message ?: "the camera couldn't start")
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    cameraEnded(camera, "Another app took the camera, or HollerShare went to the background")
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    cameraEnded(camera, "The camera stopped (error $error)")
                }

                private fun cameraEnded(camera: CameraDevice, why: String) {
                    camera.close()
                    if (!currentAttempt()) return
                    repeatCapture = null
                    gone(why)
                    failed(why)
                }
            })
        } catch (_: SecurityException) {
            throw OrielExtensionError("permission_denied", "HollerShare may not use the camera")
        }
        val opened = ready.await(OPEN_TIMEOUT_S, TimeUnit.SECONDS)
        problem.get()?.let { throw OrielExtensionError("camera_failed", it) }
        if (!opened) throw OrielExtensionError("camera_failed", "the camera took too long to open")
    }

    /**
     * The steadiest range that reaches `wanted` frames a second (fewer frames
     * let the camera expose longer in low light), else the one that reaches 30.
     */
    private fun fpsRange(characteristics: CameraCharacteristics, wanted: Int): Range<Int> {
        val ranges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES) ?: return Range(wanted, wanted)
        return ranges.filter { it.upper == wanted }.maxByOrNull { it.lower }
            ?: ranges.filter { it.upper == 30 }.maxByOrNull { it.lower }
            ?: ranges.maxBy { it.upper }
    }

    private fun closeNow() {
        repeatCapture = null
        try { session?.close() } catch (e: Exception) { Log.w(TAG, "Couldn't close the capture session", e) }
        try { device?.close() } catch (e: Exception) { Log.w(TAG, "Couldn't close the camera", e) }
        try { reader?.close() } catch (e: Exception) { Log.w(TAG, "Couldn't close the image reader", e) }
        session = null
        device = null
        reader = null
    }

    private fun gone(why: String) = lock.withLock {
        lost = why
        arrived.signalAll()
    }

    private fun publish(jpeg: ByteArray) = lock.withLock {
        latest = jpeg
        produced++
        arrived.signalAll()
    }

    /** YUV_420_888 to NV21 (turned half round when the phone lies the other way), then JPEG. */
    private fun encode(image: Image): ByteArray {
        val w = image.width
        val h = image.height
        val out = nv21?.takeIf { it.size == w * h * 3 / 2 } ?: ByteArray(w * h * 3 / 2).also { nv21 = it }
        val y = image.planes[0]
        val u = image.planes[1]
        val v = image.planes[2]
        val yBuf = y.buffer.duplicate()
        var o = 0
        if (y.rowStride == w) {
            yBuf.position(0)
            yBuf.get(out, 0, w * h)
            o = w * h
        } else {
            for (row in 0 until h) {
                yBuf.position(row * y.rowStride)
                yBuf.get(out, o, w)
                o += w
            }
        }
        // Chroma: each row in one bulk read, then interleaved V,U from plain
        // arrays. Reading byte by byte from the buffers took 10 ms of a 720p
        // frame (0.4 ms this way), the most of any step.
        val uBuf = u.buffer.duplicate()
        val vBuf = v.buffer.duplicate()
        val uvRows = h / 2
        val uvCols = w / 2
        val ups = u.pixelStride
        val vps = v.pixelStride
        val uLen = (uvCols - 1) * ups + 1
        val vLen = (uvCols - 1) * vps + 1
        val uRow = uRowBuf?.takeIf { it.size >= uLen } ?: ByteArray(uLen).also { uRowBuf = it }
        val vRow = vRowBuf?.takeIf { it.size >= vLen } ?: ByteArray(vLen).also { vRowBuf = it }
        for (row in 0 until uvRows) {
            uBuf.position(row * u.rowStride)
            uBuf.get(uRow, 0, uLen)
            vBuf.position(row * v.rowStride)
            vBuf.get(vRow, 0, vLen)
            var ui = 0
            var vi = 0
            for (col in 0 until uvCols) {
                out[o++] = vRow[vi]
                out[o++] = uRow[ui]
                ui += ups
                vi += vps
            }
        }
        val rotation = (uprightRotation() + extraRotation) % 360
        val frame = when {
            rotation == 0 && !mirror -> out
            rotation == 180 && !mirror -> out.also { turnHalfRound(it, w, h) }
            else -> {
                val dst = turned?.takeIf { it.size == out.size } ?: ByteArray(out.size).also { turned = it }
                turn(out, dst, w, h, rotation, mirror, fill)
                dst
            }
        }
        val jpeg = ByteArrayOutputStream(w * h / 8)
        YuvImage(frame, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), jpegQuality, jpeg)
        return jpeg.toByteArray()
    }

    /** The clockwise turn that makes the sensor's picture upright for how the phone is held. */
    private fun uprightRotation(): Int {
        val d = deviceDegrees
        return if (facing == CameraCharacteristics.LENS_FACING_FRONT) (sensorOrientation - d + 360) % 360
        else (sensorOrientation + d) % 360
    }

    /** Follow how the phone is held, from its motion sensor (the screen may be locked upright). */
    private fun watchOrientation(on: Boolean) {
        if (!on) {
            val listener = orientation
            orientation = null
            listener?.disable()
            return
        }
        if (orientation != null) return
        val listener = object : OrientationEventListener(OrielRuntime.app) {
            override fun onOrientationChanged(degrees: Int) {
                if (degrees == ORIENTATION_UNKNOWN) return // lying flat: keep the last one
                val quarter = (degrees + 45) / 90 % 4 * 90
                val off = Math.abs(degrees - quarter).let { if (it > 180) 360 - it else it }
                // Only near a quarter turn, so a tilted phone doesn't flip back and forth.
                if (off <= 30) deviceDegrees = quarter
            }
        }
        orientation = listener
        if (listener.canDetectOrientation()) listener.enable()
    }

    /**
     * NV21 `src` (w x h) turned `rotation` degrees clockwise, mirrored, into
     * `dst` of the same size: a portrait result is fitted with black bars,
     * or fills the frame and is cropped. Nearest pixel: cheap enough at 30 fps.
     */
    private fun turn(src: ByteArray, dst: ByteArray, w: Int, h: Int, rotation: Int, mirror: Boolean, fill: Boolean) {
        val quarter = rotation % 180 != 0
        val rw = if (quarter) h else w
        val rh = if (quarter) w else h
        val scale = if (fill) maxOf(w.toDouble() / rw, h.toDouble() / rh) else minOf(w.toDouble() / rw, h.toDouble() / rh)
        val offX = (w - rw * scale) / 2
        val offY = (h - rh * scale) / 2
        // Where output point (ox, oy) comes from in the source, both in pixels.
        val sx = DoubleArray(3)
        val sy = DoubleArray(3)
        fun map(ox: Double, oy: Double, i: Int) {
            var u = (ox - offX) / scale
            val v = (oy - offY) / scale
            if (mirror) u = rw - u
            when (rotation) {
                0 -> { sx[i] = u; sy[i] = v }
                90 -> { sx[i] = v; sy[i] = h - u }
                180 -> { sx[i] = w - u; sy[i] = h - v }
                else -> { sx[i] = w - v; sy[i] = u }
            }
        }
        // The map is affine: its value at the origin and one step along each axis.
        map(0.0, 0.0, 0); map(1.0, 0.0, 1); map(0.0, 1.0, 2)
        val ax = sx[1] - sx[0]; val ay = sy[1] - sy[0] // per output column
        val bx = sx[2] - sx[0]; val by = sy[2] - sy[0] // per output row
        val fx = 65536.0
        // Luma: sample at pixel centres.
        val lax = (ax * fx).toInt(); val lay = (ay * fx).toInt()
        var o = 0
        for (row in 0 until h) {
            val cx = sx[0] + ax * 0.5 + bx * (row + 0.5)
            val cy = sy[0] + ay * 0.5 + by * (row + 0.5)
            var x = (cx * fx).toInt(); var y = (cy * fx).toInt()
            for (col in 0 until w) {
                val xi = x shr 16; val yi = y shr 16
                dst[o++] = if (xi in 0 until w && yi in 0 until h) src[yi * w + xi] else 0
                x += lax; y += lay
            }
        }
        // Chroma: VU pairs at half size, sampled at the centre of each 2x2 block.
        val cw = w / 2; val ch = h / 2
        val cax = (ax * fx).toInt(); val cay = (ay * fx).toInt() // two output pixels, halved
        val base = w * h
        for (row in 0 until ch) {
            val cx = (sx[0] + ax + bx * (2 * row + 1)) / 2
            val cy = (sy[0] + ay + by * (2 * row + 1)) / 2
            var x = (cx * fx).toInt(); var y = (cy * fx).toInt()
            for (col in 0 until cw) {
                val xi = x shr 16; val yi = y shr 16
                if (xi in 0 until cw && yi in 0 until ch) {
                    val i = base + (yi * cw + xi) * 2
                    dst[o++] = src[i]; dst[o++] = src[i + 1]
                } else {
                    dst[o++] = -128; dst[o++] = -128
                }
                x += cax; y += cay
            }
        }
    }

    /** Rotate an NV21 frame by 180 degrees in place. */
    private fun turnHalfRound(data: ByteArray, w: Int, h: Int) {
        var a = 0
        var b = w * h - 1
        while (a < b) {
            val t = data[a]; data[a] = data[b]; data[b] = t
            a++; b--
        }
        // VU pairs: reverse the pairs, keeping V before U.
        a = w * h
        b = w * h * 3 / 2 - 2
        while (a < b) {
            val v0 = data[a]; val u0 = data[a + 1]
            data[a] = data[b]; data[a + 1] = data[b + 1]
            data[b] = v0; data[b + 1] = u0
            a += 2; b -= 2
        }
    }

    private fun keepScreenOn(on: Boolean) {
        val window = if (on) OrielRuntime.foreground?.window else screenWindow
        screenWindow = if (on) window else null
        if (window == null) return
        // Queue both changes on the same handler, even when termination runs on the UI thread.
        mainHandler.post {
            if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}
