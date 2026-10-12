package com.example.api_testing

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * Safety rules for documents received from other apps. Free of Android types
 * so they can be checked on a plain JVM.
 */
internal object IncomingFiles {
    const val MAX_NAME_LENGTH = 120

    /** Generous for scanned books; stops a sender from filling storage. */
    const val MAX_BYTES = 1L shl 30

    class TooLargeException : IOException("Document too large")

    /** Reduces an untrusted display name to a plain, bounded file name. */
    fun safeFileName(raw: String?): String {
        val base = (raw ?: "")
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .filter { it >= ' ' && it != '\u007F' }
            .trim()
            .take(MAX_NAME_LENGTH)
        return if (base.isEmpty() || base == "." || base == "..") "document" else base
    }

    /** Whether [file] resolves to a location strictly inside [directory]. */
    fun isInside(directory: File, file: File): Boolean =
        file.canonicalPath.startsWith(directory.canonicalPath + File.separator)

    /** Copies [input] to [output], failing once more than [maxBytes] arrive. */
    fun copyBounded(input: InputStream, output: OutputStream, maxBytes: Long = MAX_BYTES) {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) return
            total += read
            if (total > maxBytes) throw TooLargeException()
            output.write(buffer, 0, read)
        }
    }
}
