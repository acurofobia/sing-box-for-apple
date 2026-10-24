package io.whitelink.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/** Secrets and the installation identifier live in noBackupFilesDir, never preferences. */
class ProfileStore(context: Context) : ProfileStorage {
    private val appContext = context.applicationContext
    private val directory = File(appContext.noBackupFilesDir, "whitelink-profile")
    private val snapshotFile = AtomicFile(File(directory, "snapshot.aesgcm"))
    private val deviceFile = AtomicFile(File(directory, "installation-id"))
    private val keyAlias = "${appContext.packageName}.profile.aesgcm.v1"

    override val deviceId: String
        get() = synchronized(LOCK) {
            ensureDirectory()
            try {
                val existing = deviceFile.openRead().use { input ->
                    ConfigurationParser.decodeUtf8(readLimited(input, 128)).trim()
                }
                if (!UUID_PATTERN.matches(existing)) storageError()
                UUID.fromString(existing)
                existing
            } catch (_: FileNotFoundException) {
                UUID.randomUUID().toString().also { atomicWrite(deviceFile, it.toByteArray(Charsets.UTF_8)) }
            } catch (_: Exception) {
                storageError()
            }
        }

    override fun load(): Snapshot = synchronized(LOCK) {
        ensureDirectory()
        val bytes = try {
            snapshotFile.openRead().use { readLimited(it, MAX_SNAPSHOT_BYTES + 64) }
        } catch (_: FileNotFoundException) {
            return@synchronized Snapshot()
        } catch (_: Exception) {
            storageError()
        }
        var clear: ByteArray? = null
        try {
            if (bytes.size < MAGIC.size + IV_BYTES + 16 || !bytes.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) storageError()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, bytes.copyOfRange(MAGIC.size, MAGIC.size + IV_BYTES)))
            cipher.updateAAD(MAGIC)
            clear = cipher.doFinal(bytes, MAGIC.size + IV_BYTES, bytes.size - MAGIC.size - IV_BYTES)
            val root = StrictJson.objectValue(ConfigurationParser.decodeUtf8(clear), MAX_SNAPSHOT_BYTES)
            if (ConfigurationParser.integer(root.opt("schema"), 1..1) != 1) storageError()
            val source = nullableString(root, "source")
            val vless = nullableString(root, "vless")
            val turn = nullableString(root, "turn")
            val time = root.opt("updatedAt") as? Number ?: storageError()
            if (time.toDouble() < 0 || time.toDouble() != time.toLong().toDouble()) storageError()
            val mode = SelectedMode.valueOf(root.getString("selectedMode"))
            normalized(Snapshot(source, vless, turn, time.toLong(), mode))
        } catch (_: Exception) {
            storageError()
        } finally {
            clear?.fill(0)
            bytes.fill(0)
        }
    }

    /** Encryption completes before AtomicFile can replace the previous valid snapshot. */
    override fun save(snapshot: Snapshot) = synchronized(LOCK) {
        ensureDirectory()
        val valid = normalized(snapshot)
        val root = JSONObject().put("schema", 1)
            .put("source", valid.source ?: JSONObject.NULL)
            .put("vless", valid.vless ?: JSONObject.NULL)
            .put("turn", valid.turn ?: JSONObject.NULL)
            .put("updatedAt", valid.updatedAt).put("selectedMode", valid.selectedMode.name)
        val clear = root.toString().toByteArray(Charsets.UTF_8)
        try {
            if (clear.size > MAX_SNAPSHOT_BYTES) storageError()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
            cipher.updateAAD(MAGIC)
            if (cipher.iv.size != IV_BYTES) storageError()
            val encrypted = cipher.doFinal(clear)
            atomicWrite(snapshotFile, MAGIC + cipher.iv + encrypted)
        } catch (_: Exception) {
            throw ProfileException("Не удалось сохранить конфигурации. Предыдущий снимок сохранён.")
        } finally {
            clear.fill(0)
        }
    }

    fun selectedMode(): SelectedMode = load().selectedMode

    fun selectMode(mode: SelectedMode) = synchronized(LOCK) {
        val snapshot = load()
        if (!snapshot.hasMode(mode)) throw ProfileException("Импортируйте конфигурацию выбранного режима.")
        save(snapshot.copy(selectedMode = mode))
    }

    fun connections(): Int {
        val turn = load().turn ?: return 30
        return JSONObject(turn).getJSONObject("proxy").getInt("num_conns")
    }

    fun setConnections(count: Int) = synchronized(LOCK) {
        if (count !in 1..50) throw ProfileException("Число TURN-соединений должно быть от 1 до 50.")
        val snapshot = load()
        val turn = snapshot.turn ?: throw ProfileException("Сначала импортируйте конфигурацию VK TURN.")
        val root = JSONObject(turn)
        root.getJSONObject("proxy").put("num_conns", count)
        save(snapshot.copy(turn = root.toString()))
    }

    override fun clear() = save(Snapshot())

    /** Preserve the latest mode/other settings when a download completes concurrently. */
    override fun mutate(recoverCorruptSnapshot: Boolean, transform: (Snapshot) -> Snapshot): Snapshot = synchronized(LOCK) {
        val previous = try { load() } catch (error: ProfileException) {
            if (!recoverCorruptSnapshot) throw error
            Snapshot()
        }
        val next = normalized(transform(previous))
        save(next)
        next
    }

    private fun normalized(snapshot: Snapshot): Snapshot {
        if (snapshot.updatedAt < 0 || (snapshot.source?.toByteArray(Charsets.UTF_8)?.size ?: 0) > 16_384) storageError()
        val vless = snapshot.vless?.let { ConfigurationParser.parseVless(it) ?: storageError() }
        val turn = snapshot.turn?.let { ConfigurationParser.validateStoredTurn(it, deviceId) }
        return snapshot.copy(vless = vless, turn = turn).withAvailableMode()
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(keyAlias, null)
        if (existing is SecretKey) return existing
        if (!create) storageError()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .setUserAuthenticationRequired(false)
                .build())
        }.generateKey()
    }

    private fun ensureDirectory() {
        if (!directory.isDirectory && !directory.mkdirs()) storageError()
    }

    private fun nullableString(root: JSONObject, name: String): String? {
        if (!root.has(name)) storageError()
        if (root.isNull(name)) return null
        return root.opt(name) as? String ?: storageError()
    }

    private fun atomicWrite(file: AtomicFile, bytes: ByteArray) {
        val output = file.startWrite()
        try {
            output.write(bytes)
            output.flush()
            output.fd.sync()
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    private fun readLimited(input: java.io.InputStream, maxBytes: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return output.toByteArray()
            if (output.size() > maxBytes - count) storageError()
            output.write(buffer, 0, count)
        }
    }

    private fun storageError(): Nothing = throw ProfileException("Сохранённые настройки недоступны или повреждены. Требуется повторный импорт.")

    private companion object {
        val LOCK = Any()
        val MAGIC = "WLSP1".toByteArray(Charsets.US_ASCII)
        val UUID_PATTERN = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        const val IV_BYTES = 12
        const val MAX_SNAPSHOT_BYTES = 20 * 1024 * 1024
    }
}
