package com.example.api_testing

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class IncomingFilesTest {
    private val hostileNames = listOf(
        null to "document",
        "" to "document",
        "   " to "document",
        "." to "document",
        ".." to "document",
        "dir/" to "document",
        "../../databases/lectern.sqlite" to "lectern.sqlite",
        "..\\..\\shared_prefs\\settings.xml" to "settings.xml",
        "a\u0000b\nc.pdf" to "abc.pdf",
        "  Book.epub  " to "Book.epub",
        "Ünïcødé 書.txt" to "Ünïcødé 書.txt",
        "x".repeat(300) to "x".repeat(IncomingFiles.MAX_NAME_LENGTH),
    )

    @Test
    fun safeFileNameKeepsOnlyAPlainName() {
        for ((raw, expected) in hostileNames) {
            assertEquals("for $raw", expected, IncomingFiles.safeFileName(raw))
        }
    }

    @Test
    fun sanitisedNamesStayInsideTheDirectory() {
        val directory = Files.createTempDirectory("incoming").toFile()
        try {
            for ((raw, _) in hostileNames) {
                val name = IncomingFiles.safeFileName(raw)
                assertTrue(name, IncomingFiles.isInside(directory, File(directory, name)))
            }
            assertFalse(IncomingFiles.isInside(directory, File(directory, "..")))
            assertFalse(IncomingFiles.isInside(directory, File(directory, ".")))
            assertFalse(IncomingFiles.isInside(directory, File(directory.path + "x", "a")))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun copyBoundedCopiesUpToTheLimit() {
        val data = ByteArray(200_000) { it.toByte() }
        val output = ByteArrayOutputStream()
        IncomingFiles.copyBounded(ByteArrayInputStream(data), output, maxBytes = 200_000)
        assertArrayEquals(data, output.toByteArray())
    }

    @Test
    fun copyBoundedStopsPastTheLimit() {
        val data = ByteArray(200_000)
        assertThrows(IncomingFiles.TooLargeException::class.java) {
            IncomingFiles.copyBounded(ByteArrayInputStream(data), ByteArrayOutputStream(), maxBytes = 199_999)
        }
    }
}
