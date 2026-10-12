package com.example.api_testing

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Receives documents from other apps ("Open with" and the share sheet) and
 * hands them to Dart as files in the app cache, from where the importer
 * moves them into the library.
 *
 * Security: everything about an incoming document is untrusted. Only
 * content:// URIs are read, and [IncomingFiles] reduces the sender's display
 * name to a plain file name, keeps the copy inside a fresh directory (so a
 * crafted name can never write elsewhere in app storage) and caps its size.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Documents received before Dart asked for them (e.g. on a cold start). */
    private val pending = mutableListOf<Map<String, String>>()
    private var dartReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" -> {
                    dartReady = true
                    val items = ArrayList(pending)
                    pending.clear()
                    result.success(items)
                }
                else -> result.notImplemented()
            }
        }
        channel = methodChannel
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A restored activity, or one relaunched from Recents, carries the
        // intent that was already handled when it first arrived.
        val fromHistory = (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (savedInstanceState == null && !fromHistory) handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        // Lets a copy in progress finish; accepts no new work.
        executor.shutdown()
        super.onDestroy()
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = when (intent.action) {
            Intent.ACTION_VIEW -> ACTION_OPEN
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> ACTION_SHARE
            else -> return
        }
        val uris = incomingUris(intent)
        if (uris.isEmpty()) return
        // Read grants last as long as this activity, so copying in the
        // background is safe.
        executor.execute {
            val received = uris.map { receive(it, action) }
            mainHandler.post { deliver(received) }
        }
    }

    private fun incomingUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_VIEW -> listOfNotNull(intent.data)
        Intent.ACTION_SEND -> listOfNotNull(streamExtra(intent))
        Intent.ACTION_SEND_MULTIPLE -> streamListExtra(intent)
        else -> emptyList()
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun streamListExtra(intent: Intent): List<Uri> {
        val list: List<Uri>? =
            if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            }
        return list ?: emptyList()
    }

    private fun deliver(received: List<Map<String, String>>) {
        val target = channel
        if (dartReady && target != null) {
            target.invokeMethod("documentsReceived", received)
        } else {
            pending.addAll(received)
        }
    }

    /**
     * Copies [uri] into a new directory in the cache. Returns its path and
     * name, or its name and an error code if it could not be copied.
     */
    private fun receive(uri: Uri, action: String): Map<String, String> {
        val name = IncomingFiles.safeFileName(displayName(uri))
        val result = mapOf(KEY_ACTION to action, KEY_NAME to name)
        if (uri.scheme != "content") return result + (KEY_ERROR to ERROR_UNREADABLE)
        val directory = File(cacheDir, "$INCOMING_DIR/${UUID.randomUUID()}")
        return try {
            if (!directory.mkdirs()) throw IOException("Could not create a directory")
            val target = File(directory, name)
            if (!IncomingFiles.isInside(directory, target)) throw IOException("Unsafe file name")
            val stream = contentResolver.openInputStream(uri) ?: throw IOException("No content")
            stream.use { input ->
                target.outputStream().use { output -> IncomingFiles.copyBounded(input, output) }
            }
            result + (KEY_PATH to target.absolutePath)
        } catch (e: IncomingFiles.TooLargeException) {
            directory.deleteRecursively()
            result + (KEY_ERROR to ERROR_TOO_LARGE)
        } catch (e: Exception) {
            // SecurityException (no read grant), IOException, etc.
            directory.deleteRecursively()
            result + (KEY_ERROR to ERROR_UNREADABLE)
        }
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme != "content") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
                }
        } catch (e: Exception) {
            null
        } ?: uri.lastPathSegment
    }

    companion object {
        private const val CHANNEL = "lectern/incoming_documents"
        private const val INCOMING_DIR = "incoming"
        private const val KEY_ACTION = "action"
        private const val KEY_NAME = "name"
        private const val KEY_PATH = "path"
        private const val KEY_ERROR = "error"
        private const val ACTION_OPEN = "open"
        private const val ACTION_SHARE = "share"
        private const val ERROR_UNREADABLE = "unreadable"
        private const val ERROR_TOO_LARGE = "tooLarge"
    }
}
