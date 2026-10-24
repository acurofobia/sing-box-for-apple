package io.whitelink.android.data

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class SubscriptionRepositoryTest {
    private lateinit var server: ServerSocket
    private lateinit var acceptThread: Thread
    private lateinit var workers: ThreadPoolExecutor
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    private lateinit var storage: MemoryStorage
    private lateinit var repository: SubscriptionRepository
    private val responses = ConcurrentHashMap<String, Response>()
    private val requests = ConcurrentLinkedQueue<String>()
    private val previous = Snapshot("https://old.example.test/token", "old-vless", "old-turn", 123L, SelectedMode.TURN)
    private val validTurn = "wdtt://relay.example.test:443:x:x:test-password:hash"
    private val validVless = "{\"type\":\"vless\",\"server\":\"vpn.example.test\",\"server_port\":443,\"uuid\":\"11111111-1111-4111-8111-111111111111\"}"

    @Before fun setUp() {
        storage = MemoryStorage(previous)
        repository = SubscriptionRepository(storage, allowDebugHttp = true)
        server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        workers = ThreadPoolExecutor(2, 4, 1, TimeUnit.SECONDS, ArrayBlockingQueue(16),
            { runnable -> Thread(runnable, "subscription-test-http").apply { isDaemon = true } },
            ThreadPoolExecutor.AbortPolicy())
        acceptThread = Thread({
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: Exception) { break }
                sockets.add(socket)
                try { workers.execute { respond(socket) } } catch (_: Exception) {
                    sockets.remove(socket)
                    runCatching { socket.close() }
                }
            }
        }, "subscription-test-accept").apply { isDaemon = true; start() }
    }

    @After fun tearDown() {
        server.close()
        sockets.forEach { runCatching { it.close() } }
        workers.shutdownNow()
        acceptThread.join(2000)
        workers.awaitTermination(2, TimeUnit.SECONDS)
        sockets.clear()
    }

    private fun respond(socket: Socket) {
        try {
            socket.soTimeout = 2000
            val input = BufferedInputStream(socket.getInputStream())
            val firstLine = headerLine(input) ?: return
            val request = firstLine.split(' ', limit = 3)
            if (request.size != 3 || request[0] != "GET") return
            var headerCount = 0
            while (true) {
                val line = headerLine(input) ?: return
                if (line.isEmpty()) break
                if (++headerCount > 64) return
            }
            val path = URI(request[1]).path
            requests.add(path)
            val response = responses[path] ?: Response(404, "missing")
            if (response.delayMs > 0) Thread.sleep(response.delayMs)
            val bytes = if (response.gzip) {
                ByteArrayOutputStream().apply {
                    GZIPOutputStream(this).use { it.write(response.text.toByteArray(Charsets.UTF_8)) }
                }.toByteArray()
            } else response.text.toByteArray(Charsets.UTF_8)
            val headers = buildString {
                append("HTTP/1.1 ${response.status} Test\r\n")
                append("Content-Type: application/json; charset=utf-8\r\n")
                append("Content-Length: ${response.advertisedLength ?: bytes.size.toLong()}\r\n")
                append("Connection: close\r\n")
                if (response.gzip) append("Content-Encoding: gzip\r\n")
                response.headers.forEach { (name, value) -> append("$name: $value\r\n") }
                append("\r\n")
            }
            socket.getOutputStream().use { output ->
                output.write(headers.toByteArray(Charsets.US_ASCII))
                output.write(bytes)
                output.flush()
            }
        } catch (_: Exception) {
            // Cancellation and cap checks deliberately close an in-flight response.
        } finally {
            sockets.remove(socket)
            runCatching { socket.close() }
        }
    }

    private fun headerLine(input: InputStream): String? {
        val line = StringBuilder()
        while (line.length <= 8192) {
            val byte = input.read()
            if (byte < 0) return null
            if (byte == '\n'.code) return line.toString().removeSuffix("\r")
            line.append(byte.toChar())
        }
        throw IllegalArgumentException("HTTP test header exceeds limit")
    }

    @Test fun validSubscriptionCommitsBothModesOnce() = runBlocking {
        responses["/subscription"] = Response(200, manifest(url("/config"), validTurn))
        responses["/config"] = Response(200, validVless)
        val result = repository.update(url("/subscription"))
        assertEquals(1, storage.commits)
        assertEquals(SelectedMode.TURN, result.snapshot.selectedMode)
        assertNotNull(result.snapshot.vless)
        assertNotNull(result.snapshot.turn)
        assertEquals(url("/subscription"), result.snapshot.source)
        assertTrue(result.warnings.isEmpty())
    }

    @Test fun badVlessDisablesOnlyVlessAndKeepsValidTurn() = runBlocking {
        responses["/subscription"] = Response(200, manifest(url("/config"), validTurn))
        responses["/config"] = Response(200, "{\"type\":\"vless\",\"uuid\":\"bad\"}")
        val result = repository.update(url("/subscription"))
        assertNull(result.snapshot.vless)
        assertNotNull(result.snapshot.turn)
        assertEquals(1, storage.commits)
        assertEquals(1, result.warnings.size)
    }

    @Test fun badTurnKeepsValidVlessAndSwitchesUnavailableMode() = runBlocking {
        responses["/subscription"] = Response(200, manifest(url("/config"), "unsupported://opaque"))
        responses["/config"] = Response(200, validVless)
        val result = repository.update(url("/subscription"))
        assertNotNull(result.snapshot.vless)
        assertNull(result.snapshot.turn)
        assertEquals(SelectedMode.VLESS, result.snapshot.selectedMode)
        assertEquals(1, result.warnings.size)
    }

    @Test fun explicitNullsClearBothModes() = runBlocking {
        responses["/subscription"] = Response(200, "{\"sing_box_url\":null,\"vk_turn_link\":null}")
        val result = repository.update(url("/subscription"))
        assertNull(result.snapshot.vless)
        assertNull(result.snapshot.turn)
        assertEquals(1, storage.commits)
    }

    @Test fun malformedManifestPreservesWholePreviousSnapshot() = runBlocking {
        listOf("[]", "{\"sing_box_url\":null,}", "{}{}", "{\"sing_box_url\":null,\"sing_box_url\":null}").forEach {
            responses["/subscription"] = Response(200, it)
            rejectsUpdate()
            assertEquals(previous, storage.load())
            assertEquals(0, storage.commits)
        }
    }

    @Test fun non200ConfigDownloadPreservesBothPreviousModes() = runBlocking {
        responses["/subscription"] = Response(200, manifest(url("/config"), validTurn))
        responses["/config"] = Response(403, "secret-error-body")
        rejectsUpdate()
        assertEquals(previous, storage.load())
        assertEquals(0, storage.commits)
    }

    @Test fun redirectsAreNeverFollowedAndDoNotCommit() = runBlocking {
        responses["/subscription"] = Response(302, "redirect", headers = mapOf("Location" to url("/following")))
        responses["/following"] = Response(200, manifest(null, validTurn))
        rejectsUpdate()
        assertEquals(listOf("/subscription"), requests.toList())
        assertEquals(previous, storage.load())
        assertEquals(0, storage.commits)
    }

    @Test fun differentOriginIsRejectedBeforeConfigRequest() = runBlocking {
        responses["/subscription"] = Response(200, manifest("http://127.0.0.1:${server.localPort + 1}/config", validTurn))
        rejectsUpdate()
        assertEquals(listOf("/subscription"), requests.toList())
        assertEquals(previous, storage.load())
    }

    @Test fun manifestCapIncludesDecompressedGzipBytes() = runBlocking {
        responses["/subscription"] = Response(200, "{\"padding\":\"${"a".repeat(128 * 1024)}\"}", gzip = true)
        rejectsUpdate()
        assertEquals(previous, storage.load())
        assertEquals(0, storage.commits)
    }

    @Test fun configContentLengthCapPreservesPreviousSnapshot() = runBlocking {
        responses["/subscription"] = Response(200, manifest(url("/config"), validTurn))
        responses["/config"] = Response(200, "{}", advertisedLength = ConfigurationParser.MAX_CONFIG_BYTES.toLong() + 1)
        rejectsUpdate()
        assertEquals(previous, storage.load())
        assertEquals(0, storage.commits)
    }

    @Test fun cancellationClosesRequestWithoutAnyCommit() = runBlocking {
        responses["/subscription"] = Response(200, manifest(null, validTurn), delayMs = 1000)
        val task = async(Dispatchers.IO) { repository.update(url("/subscription")) }
        delay(100)
        task.cancel()
        task.join()
        assertEquals(previous, storage.load())
        assertEquals(0, storage.commits)
    }

    @Test fun releasePolicyRejectsLocalHttpAndUrlUserinfoAndFragment() = runBlocking {
        repository = SubscriptionRepository(storage, allowDebugHttp = false)
        rejectsUpdate()
        repository = SubscriptionRepository(storage, allowDebugHttp = true)
        listOf("http://name:password@127.0.0.1:${server.localPort}/subscription", url("/subscription#secret"), "http://public.example.test/subscription").forEach { source ->
            try { repository.update(source); fail("Expected URL rejection") } catch (error: ProfileException) {
                assertSanitizedCauseChain(error, source, "name:password@", "password")
            }
        }
        assertEquals(0, storage.commits)
        assertTrue(requests.isEmpty())
    }

    @Test fun manualImportDetachesSourceAndPreservesOtherMode() {
        val result = repository.importVless(validVless)
        assertNull(result.snapshot.source)
        assertEquals(previous.turn, result.snapshot.turn)
        assertNotNull(result.snapshot.vless)
    }

    private suspend fun rejectsUpdate() {
        try { repository.update(url("/subscription")); fail("Expected transaction rejection") } catch (error: ProfileException) {
            assertSanitizedCauseChain(error, "secret-error-body", url("/subscription"),
                previous.source!!, "test-password")
        }
    }

    private fun assertSanitizedCauseChain(error: Throwable, vararg forbiddenValues: String) {
        // Coroutine stacktrace recovery may copy a sanitized ProfileException
        // and attach its original as cause. The security invariant is redaction
        // throughout that chain, independent of recovery being enabled by -ea.
        val seen = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Throwable, Boolean>())
        var current: Throwable? = error
        var depth = 0
        val forbidden = forbiddenValues.toList() + listOf("http://", "https://", "wdtt://", "vkturnproxy://")
        while (current != null) {
            assertTrue("Exception cause chain exceeds the bounded inspection limit", depth++ < 8)
            assertTrue("Exception cause chain contains a cycle", seen.add(current))
            val message = current.message.orEmpty()
            forbidden.forEach { value ->
                assertFalse("Exception cause chain leaked a URL or secret", message.contains(value, ignoreCase = true))
            }
            current = current.cause
        }
    }

    private fun manifest(config: String?, turn: String?): String = JSONObject()
        .put("sing_box_url", config ?: JSONObject.NULL).put("vk_turn_link", turn ?: JSONObject.NULL).toString()
    private fun url(path: String): String = "http://127.0.0.1:${server.localPort}$path"

    private data class Response(val status: Int, val text: String, val gzip: Boolean = false,
        val headers: Map<String, String> = emptyMap(), val advertisedLength: Long? = null, val delayMs: Long = 0)

    private class MemoryStorage(private var snapshot: Snapshot) : ProfileStorage {
        override val deviceId = "test-installation-id"
        var commits = 0
        @Synchronized override fun load(): Snapshot = snapshot
        @Synchronized override fun save(snapshot: Snapshot) { this.snapshot = snapshot; commits++ }
        override fun clear() = save(Snapshot())
        @Synchronized override fun mutate(recoverCorruptSnapshot: Boolean, transform: (Snapshot) -> Snapshot): Snapshot {
            val result = transform(snapshot)
            save(result)
            return result
        }
    }
}
