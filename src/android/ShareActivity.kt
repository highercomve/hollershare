package dev.hollershare

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import androidx.annotation.Keep
import dev.oriel.OrielMainActivity
import dev.oriel.OrielRuntime
import java.io.File
import java.io.FileOutputStream
import org.json.JSONArray
import org.json.JSONObject

/**
 * Trampoline activity for Android's system Share Sheet (ACTION_SEND and ACTION_SEND_MULTIPLE).
 * Receives shared files, photos, or text from other apps, stages incoming content URIs into
 * HollerShare's staging cache, and forwards the items to OrielMainActivity to initiate a Quick Share transfer.
 */
@Keep
class ShareActivity : Activity() {
    companion object {
        private const val TAG = "HollerShare"
        // What one share may stage: the engine sends at most 1024 files,
        // and text over 1 MB doesn't fit an Intent extra.
        private const val MAX_FILES = 1024
        private const val MAX_TOTAL_BYTES = 8L * 1024 * 1024 * 1024
        private const val MAX_TEXT_CHARS = 1_000_000
        private const val MAX_UNIQUE_NAMES = 10_000
        // Staged shares older than this are removed; a newer one may still
        // be sending.
        private const val STALE_SHARE_MS = 24L * 60 * 60 * 1000
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shared = intent
        // Copying shared files can take long (large videos): off the UI
        // thread, so the app doesn't stop responding. The activity stays
        // until the copy ends, keeping its read access to the shared URIs.
        Thread({
            try {
                handleIntent(shared)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to handle share intent", e)
            } finally {
                runOnUiThread { finish() }
            }
        }, "hollershare-share").start()
    }

    private fun handleIntent(intent: Intent) {
        val action = intent.action
        if (Intent.ACTION_SEND == action) {
            val streamUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }

            if (streamUri != null) {
                stageAndLaunch(listOf(streamUri))
                return
            }

            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                ?: intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            if (!text.isNullOrEmpty()) {
                if (text.length > MAX_TEXT_CHARS) {
                    Log.w(TAG, "Shared text of ${text.length} characters cut to $MAX_TEXT_CHARS")
                }
                launchWithText(text.take(MAX_TEXT_CHARS))
                return
            }
        } else if (Intent.ACTION_SEND_MULTIPLE == action) {
            val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }

            if (!uris.isNullOrEmpty()) {
                stageAndLaunch(uris.filterNotNull())
                return
            }
        }
    }

    private fun stageAndLaunch(uris: List<Uri>) {
        // Each share gets its own folder: a new share must not delete files
        // an earlier one is still sending.
        val root = File(cacheDir, "shared_outgoing")
        removeStaleShares(root)
        val stagingDir = File(root, System.currentTimeMillis().toString())
        if (!stagingDir.mkdirs() && !stagingDir.isDirectory) {
            Log.w(TAG, "Could not create the share staging folder")
            return
        }

        val filesArray = JSONArray()
        var fallbackIndex = 0
        var totalBytes = 0L

        if (uris.size > MAX_FILES) {
            Log.w(TAG, "Share of ${uris.size} files: only the first $MAX_FILES are sent")
        }
        for (uri in uris.take(MAX_FILES)) {
            val (displayName, size) = queryFileInfo(uri)
            val baseName = sanitizeFilename(displayName ?: "shared_file_${++fallbackIndex}")
            val destFile = ensureUniqueFile(stagingDir, baseName) ?: continue

            try {
                val input = contentResolver.openInputStream(uri)
                if (input == null) {
                    Log.w(TAG, "No content for shared URI: $uri")
                    continue
                }
                val copied = input.use { source ->
                    FileOutputStream(destFile).use { output ->
                        copyAtMost(source, output, MAX_TOTAL_BYTES - totalBytes)
                    }
                }
                if (copied < 0) {
                    destFile.delete()
                    Log.w(TAG, "Share is over ${MAX_TOTAL_BYTES} bytes; the rest is not sent")
                    break
                }
                totalBytes += copied
                val fileObj = JSONObject().apply {
                    put("path", destFile.absolutePath)
                    put("name", destFile.name)
                    put("size", if (size > 0) size else copied)
                }
                filesArray.put(fileObj)
            } catch (e: Exception) {
                destFile.delete()
                Log.w(TAG, "Failed to stage incoming share URI: $uri", e)
            }
        }

        if (filesArray.length() > 0) {
            val payload = JSONObject().apply {
                put("mode", "files")
                put("files", filesArray)
            }
            launchMain(payload.toString())
        } else {
            stagingDir.delete()
        }
    }

    /** Copies at most [limit] bytes; returns the count, or -1 when the source is longer. */
    private fun copyAtMost(input: java.io.InputStream, output: FileOutputStream, limit: Long): Long {
        val buffer = ByteArray(64 * 1024)
        var copied = 0L
        while (true) {
            val n = input.read(buffer)
            if (n < 0) return copied
            if (copied + n > limit) return -1
            output.write(buffer, 0, n)
            copied += n
        }
    }

    /** Removes staged shares older than a day (and the flat files of older versions). */
    private fun removeStaleShares(root: File) {
        val now = System.currentTimeMillis()
        root.listFiles()?.forEach { entry ->
            val stamp = entry.name.toLongOrNull()
            val stale = if (entry.isDirectory && stamp != null) now - stamp > STALE_SHARE_MS else now - entry.lastModified() > STALE_SHARE_MS
            if (stale && !entry.deleteRecursively()) Log.w(TAG, "Could not remove old staged share ${entry.name}")
        }
    }

    private fun launchWithText(text: String) {
        val payload = JSONObject().apply {
            put("mode", "text")
            put("text", text)
        }
        launchMain(payload.toString())
    }

    private fun launchMain(jsonPayload: String) {
        val mainIntent = Intent(this, OrielMainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra(OrielRuntime.EXTRA_ARGS, arrayOf("--share-payload", jsonPayload))
        }
        startActivity(mainIntent)
    }

    private fun queryFileInfo(uri: Uri): Pair<String?, Long> {
        var name: String? = null
        var size: Long = -1L
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex != -1) name = cursor.getString(nameIndex)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex != -1) size = cursor.getLong(sizeIndex)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to query metadata for $uri", e)
        }
        if (name == null) {
            name = uri.lastPathSegment
        }
        return Pair(name, size)
    }

    private fun sanitizeFilename(name: String): String {
        val base = File(name).name
        val sanitized = base.replace(Regex("[/\\\\:*?\"<>|]"), "_").trim()
        return if (sanitized.isNotEmpty() && sanitized != "." && sanitized != "..") sanitized else "shared_file"
    }

    /** A name not yet used in [dir], or null after [MAX_UNIQUE_NAMES] tries. */
    private fun ensureUniqueFile(dir: File, name: String): File? {
        val first = File(dir, name)
        if (!first.exists()) return first
        val dot = name.lastIndexOf('.')
        val base = if (dot != -1) name.substring(0, dot) else name
        val ext = if (dot != -1) name.substring(dot) else ""
        for (count in 1..MAX_UNIQUE_NAMES) {
            val file = File(dir, "$base ($count)$ext")
            if (!file.exists()) return file
        }
        Log.w(TAG, "No free name for $name")
        return null
    }
}
