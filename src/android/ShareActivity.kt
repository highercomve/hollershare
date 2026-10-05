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
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            handleIntent(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to handle share intent", e)
        } finally {
            finish()
        }
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
                launchWithText(text)
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
        val stagingDir = File(cacheDir, "shared_outgoing")
        if (stagingDir.exists()) {
            stagingDir.deleteRecursively()
        }
        stagingDir.mkdirs()

        val filesArray = JSONArray()
        var fallbackIndex = 0

        for (uri in uris) {
            val (displayName, size) = queryFileInfo(uri)
            val baseName = sanitizeFilename(displayName ?: "shared_file_${++fallbackIndex}")
            val destFile = ensureUniqueFile(stagingDir, baseName)

            try {
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(destFile).use { output ->
                        input.copyTo(output)
                    }
                }
                val actualSize = if (size > 0) size else destFile.length()
                val fileObj = JSONObject().apply {
                    put("path", destFile.absolutePath)
                    put("name", destFile.name)
                    put("size", actualSize)
                }
                filesArray.put(fileObj)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to stage incoming share URI: $uri", e)
            }
        }

        if (filesArray.length() > 0) {
            val payload = JSONObject().apply {
                put("mode", "files")
                put("files", filesArray)
            }
            launchMain(payload.toString())
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
        return if (sanitized.isNotEmpty()) sanitized else "shared_file"
    }

    private fun ensureUniqueFile(dir: File, name: String): File {
        var file = File(dir, name)
        if (!file.exists()) return file
        val dot = name.lastIndexOf('.')
        val base = if (dot != -1) name.substring(0, dot) else name
        val ext = if (dot != -1) name.substring(dot) else ""
        var count = 1
        while (file.exists()) {
            file = File(dir, "$base ($count)$ext")
            count++
        }
        return file
    }
}
