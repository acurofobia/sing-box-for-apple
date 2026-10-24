package io.whitelink.android.data

import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.GZIPInputStream
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject

/** All network data is downloaded and validated before a single encrypted commit. */
class SubscriptionRepository(
    private val store: ProfileStorage,
    private val allowDebugHttp: Boolean = false,
    private val validateVless: (String) -> Unit = {},
) {
    private val updates = Mutex()

    fun load(): Snapshot = store.load()
    fun save(snapshot: Snapshot) = store.save(snapshot)

    fun importVless(text: String): ImportResult {
        val node = ConfigurationParser.parseVless(text, validateVless)
            ?: throw ProfileException("В JSON отсутствует VLESS-сервер.")
        val snapshot = store.mutate(recoverCorruptSnapshot = true) {
            it.copy(source = null, vless = node, updatedAt = System.currentTimeMillis())
        }
        return ImportResult(snapshot)
    }

    fun importTurn(text: String): ImportResult {
        val turn = ConfigurationParser.parseTurn(text, store.deviceId)
        val snapshot = store.mutate(recoverCorruptSnapshot = true) {
            it.copy(source = null, turn = turn, updatedAt = System.currentTimeMillis())
        }
        return ImportResult(snapshot)
    }

    fun clear(): ImportResult {
        store.clear()
        return ImportResult(Snapshot())
    }

    suspend fun update(source: String): ImportResult = updates.withLock {
        try {
            withTimeout(TOTAL_TIMEOUT_MS) {
                val manifestUrl = validatedUrl(source)
                val manifestBytes = download(manifestUrl, MAX_MANIFEST_BYTES)
                val manifest = try {
                    StrictJson.objectValue(ConfigurationParser.decodeUtf8(manifestBytes), MAX_MANIFEST_BYTES)
                } catch (_: Exception) {
                    throw ProfileException("Сервер вернул некорректные данные подписки. Предыдущий снимок сохранён.")
                }
                val warnings = mutableListOf<String>()
                var vless: String? = null
                var turn: String? = null
                val configSource = manifestField(manifest, "sing_box_url", warnings,
                    "Ссылка sing-box некорректна. Режим VLESS недоступен.")
                val turnSource = manifestField(manifest, "vk_turn_link", warnings,
                    "Ссылка VK TURN некорректна. Режим недоступен.")
                if (configSource != null) {
                    val configUrl = try { validatedUrl(configSource) } catch (_: ProfileException) {
                        warnings.add("Ссылка sing-box некорректна. Режим VLESS недоступен.")
                        null
                    }
                    if (configUrl != null) {
                        if (!sameOrigin(manifestUrl, configUrl)) {
                            throw ProfileException("Адрес конфигурации должен иметь тот же сервер и протокол, что подписка. Предыдущий снимок сохранён.")
                        }
                        // Download failures abort the whole transaction, including TURN.
                        val bytes = download(configUrl, ConfigurationParser.MAX_CONFIG_BYTES)
                        vless = try {
                            withContext(Dispatchers.IO) {
                                ConfigurationParser.parseVless(ConfigurationParser.decodeUtf8(bytes), validateVless)
                            }
                        } catch (error: CancellationException) {
                            throw error
                        } catch (_: Exception) {
                            warnings.add("Конфигурация VLESS некорректна. Режим недоступен.")
                            null
                        }
                        if (vless == null && warnings.none { it.startsWith("Конфигурация VLESS") }) {
                            warnings.add("Конфигурация не содержит VLESS-сервер. Режим недоступен.")
                        }
                    }
                }
                if (turnSource != null) {
                    turn = try {
                        withContext(Dispatchers.IO) { ConfigurationParser.parseTurn(turnSource, store.deviceId) }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        warnings.add("Ссылка VK TURN некорректна. Режим недоступен.")
                        null
                    }
                }
                currentCoroutineContext().ensureActive()
                val snapshot = withContext(Dispatchers.IO) {
                    currentCoroutineContext().ensureActive()
                    store.mutate(recoverCorruptSnapshot = true) {
                        it.copy(source = manifestUrl.toExternalForm(), vless = vless, turn = turn,
                            updatedAt = System.currentTimeMillis()).withAvailableMode()
                    }
                }
                ImportResult(snapshot, warnings.toList())
            }
        } catch (error: kotlinx.coroutines.TimeoutCancellationException) {
            throw ProfileException("Превышено время обновления подписки. Предыдущий снимок сохранён.")
        } catch (error: CancellationException) {
            throw error
        } catch (error: ProfileException) {
            throw error
        } catch (_: Exception) {
            throw ProfileException("Не удалось обновить подписку. Предыдущий снимок сохранён.")
        }
    }

    private fun manifestField(root: JSONObject, name: String, warnings: MutableList<String>, warning: String): String? {
        if (!root.has(name) || root.isNull(name)) return null
        val value = root.opt(name)
        if (value !is String) {
            warnings.add(warning)
            return null
        }
        return value.trim().takeIf { it.isNotEmpty() }
    }

    private fun validatedUrl(source: String): URL {
        try {
            val text = source.trim()
            if (text.length > 16_384 || text.any { it.code < 0x20 || it.code == 0x7f }) invalidUrl()
            val uri = URI(text)
            val scheme = uri.scheme?.lowercase()
            if (scheme !in listOf("https", "http") || uri.host.isNullOrBlank() ||
                uri.userInfo != null || uri.fragment != null || uri.port == 0 || uri.port > 65535) invalidUrl()
            if (scheme == "http" && (!allowDebugHttp || !isLocalDebugHost(uri.host))) {
                throw ProfileException("Для подписки нужен HTTPS. Локальный HTTP доступен в debug-сборке по адресу локальной сети.")
            }
            return uri.toURL()
        } catch (error: ProfileException) {
            throw error
        } catch (_: Exception) {
            invalidUrl()
        }
    }

    private fun isLocalDebugHost(rawHost: String): Boolean {
        val host = rawHost.lowercase().removePrefix("[").removeSuffix("]")
        if (host == "localhost" || host == "::1") return true
        val pieces = host.split('.')
        if (pieces.size != 4 || pieces.any { it.isEmpty() || it.any { char -> char !in '0'..'9' } }) return false
        val octets = pieces.map { it.toIntOrNull() ?: return false }
        if (octets.any { it !in 0..255 }) return false
        return octets[0] == 10 || octets[0] == 127 ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 172 && octets[1] in 16..31) ||
            (octets[0] == 169 && octets[1] == 254)
    }

    private fun sameOrigin(first: URL, second: URL): Boolean =
        first.protocol.equals(second.protocol, true) && first.host.equals(second.host, true) &&
            (if (first.port == -1) first.defaultPort else first.port) ==
            (if (second.port == -1) second.defaultPort else second.port)

    /** Cancellation closes the socket immediately, instead of waiting on a blocking read. */
    private suspend fun download(url: URL, maxBytes: Int): ByteArray = withTimeout(REQUEST_TIMEOUT_MS) {
        suspendCancellableCoroutine { continuation ->
            val activeConnection = AtomicReference<HttpURLConnection?>()
            continuation.invokeOnCancellation { activeConnection.get()?.disconnect() }
            Dispatchers.IO.dispatch(EmptyCoroutineContext, Runnable {
                var connection: HttpURLConnection? = null
                try {
                    if (!continuation.isActive) return@Runnable
                    val conn = url.openConnection() as HttpURLConnection
                    connection = conn
                    activeConnection.set(conn)
                    if (!continuation.isActive) return@Runnable
                    val deadline = System.nanoTime() + REQUEST_TIMEOUT_MS * 1_000_000
                    conn.instanceFollowRedirects = false
                    conn.requestMethod = "GET"
                    conn.connectTimeout = REQUEST_TIMEOUT_MS.toInt()
                    conn.readTimeout = REQUEST_TIMEOUT_MS.toInt()
                    conn.useCaches = false
                    conn.setRequestProperty("Accept", "application/json")
                    conn.setRequestProperty("Accept-Encoding", "gzip")
                    conn.setRequestProperty("Cache-Control", "no-cache")
                    if (conn.responseCode != HttpURLConnection.HTTP_OK) {
                        throw ProfileException("Сервер подписки вернул HTTP ${conn.responseCode}. Предыдущий снимок сохранён.")
                    }
                    val encoding = conn.contentEncoding?.lowercase()?.trim()
                    if (encoding != null && encoding !in listOf("identity", "gzip")) {
                        throw ProfileException("Сервер использует неподдерживаемое сжатие ответа. Предыдущий снимок сохранён.")
                    }
                    if (encoding != "gzip" && conn.contentLengthLong > maxBytes) sizeError()
                    val raw = conn.inputStream
                    val input = if (encoding == "gzip") GZIPInputStream(raw) else raw
                    val output = ByteArrayOutputStream()
                    input.use {
                        val buffer = ByteArray(8192)
                        while (true) {
                            if (!continuation.isActive) return@Runnable
                            val remainingMs = (deadline - System.nanoTime()) / 1_000_000
                            if (remainingMs <= 0) throw ProfileException("Превышено время загрузки подписки. Предыдущий снимок сохранён.")
                            conn.readTimeout = remainingMs.coerceAtMost(REQUEST_TIMEOUT_MS).coerceAtLeast(1).toInt()
                            val count = it.read(buffer)
                            if (count < 0) break
                            if (output.size() > maxBytes - count) sizeError()
                            output.write(buffer, 0, count)
                        }
                    }
                    if (continuation.isActive) continuation.resume(output.toByteArray())
                } catch (error: Exception) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(if (error is ProfileException) error else
                            ProfileException("Ошибка сети или TLS при загрузке подписки. Предыдущий снимок сохранён."))
                    }
                } finally {
                    activeConnection.set(null)
                    connection?.disconnect()
                }
            })
        }
    }

    private fun invalidUrl(): Nothing = throw ProfileException("Введите HTTP(S)-ссылку подписки без логина, пароля и фрагмента.")
    private fun sizeError(): Nothing = throw ProfileException("Ответ сервера превышает допустимый размер. Предыдущий снимок сохранён.")

    private companion object {
        const val MAX_MANIFEST_BYTES = 128 * 1024
        const val REQUEST_TIMEOUT_MS = 10_000L
        const val TOTAL_TIMEOUT_MS = 30_000L
    }
}
