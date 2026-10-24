/* SPDX-License-Identifier: GPL-3.0-or-later */
package io.whitelink.android.vpn

import android.content.Context
import android.os.Debug
import android.os.SystemClock
import io.nekohasekai.libbox.Libbox
import io.whitelink.android.data.Snapshot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CopyOnWriteArrayList

/** Redaction happens before logs reach StateFlow, disk, or a sharing target. */
internal class Diagnostics(private val context: Context) {
    data class MemorySample(val rss: Long, val pss: Long, val rssAt: Long, val pssAt: Long)
    private val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
    private val secrets = CopyOnWriteArrayList<String>()
    private var csv: File? = null
    private var output: FileOutputStream? = null
    private var started = 0L
    private var lastPssAt = 0L
    private var pss = 0L
    private var logBytes = 0L
    private val logFile = File(directory, "vpn.log")

    @Synchronized fun start(snapshot: Snapshot) {
        finish()
        secrets.clear()
        snapshot.source?.let { secrets.add(it) }
        fun visit(value: Any?) {
            when (value) {
                is JSONObject -> value.keys().forEach { key ->
                    val v = value.opt(key)
                    if (key.lowercase().contains("key") || key.lowercase().contains("password") ||
                        key.lowercase().contains("uuid") || key.lowercase().contains("link") ||
                        key.lowercase().contains("token")) {
                        if (v is String && v.isNotBlank()) secrets.add(v)
                    }
                    visit(v)
                }
                is JSONArray -> for (i in 0 until value.length()) visit(value.opt(i))
            }
        }
        snapshot.vless?.let { runCatching { visit(JSONObject(it)) } }
        snapshot.turn?.let { runCatching { visit(JSONObject(it)) } }
        started = SystemClock.elapsedRealtime()
        lastPssAt = 0
        pss = 0
        csv = File(directory, "vpn-${System.currentTimeMillis()}.csv")
        output = FileOutputStream(csv!!)
        output!!.write(("elapsed_seconds,mode,phase,generation,network,turn_active_sessions,wg_transport_tx_bytes,wg_transport_rx_bytes," +
            "user_tx_bytes,user_rx_bytes,rss_bytes,pss_bytes,go_heap_bytes,goroutines\n").toByteArray())
        logFile.writeText("")
        logBytes = 0
        VpnController.mutableLogs.value = emptyList()
        directory.listFiles()?.filter { it.extension == "csv" }?.sortedByDescending { it.name }
            ?.drop(3)?.forEach { it.delete() }
    }

    fun redact(text: String): String {
        var safe = text.take(4096)
        secrets.sortedByDescending { it.length }.forEach { if (it.length >= 3) safe = safe.replace(it, "[скрыто]") }
        safe = safe.replace(Regex("(?i)(https?://|wdtt://|vkturnproxy://)[^\\s\"']+"), "[ссылка скрыта]")
        safe = safe.replace(Regex("(?i)(private[_ -]?key|pre[_ -]?shared[_ -]?key|password|authorization|credential|token|uuid)\\s*[:=]\\s*[^,\\s]+"), "$1=[скрыто]")
        safe = safe.replace(Regex("[A-Za-z0-9+/]{43}="), "[ключ скрыт]")
        if (safe.contains("GETCONF", ignoreCase = true) || safe.contains("[Interface]", ignoreCase = true))
            safe = "[TURN] Служебные параметры подключения скрыты"
        return safe.replace('\u0000', ' ')
    }

    @Synchronized fun log(message: String) {
        val safe = redact(message)
        VpnController.mutableLogs.value = (VpnController.mutableLogs.value + safe).takeLast(1000)
        val line = safe + "\n"
        if (logBytes + line.toByteArray().size > 512 * 1024) {
            logFile.writeText("")
            logBytes = 0
        }
        runCatching { logFile.appendText(line); logBytes += line.toByteArray().size }
    }

    @Synchronized fun sample(state: VpnUiState, generation: Long, network: String, session: Long): MemorySample {
        val now = SystemClock.elapsedRealtime()
        val rss = runCatching {
            File("/proc/self/status").useLines { lines ->
                lines.firstOrNull { it.startsWith("VmRSS:") }?.trim()?.split(Regex("\\s+"))?.getOrNull(1)?.toLong()?.times(1024) ?: 0
            }
        }.getOrDefault(0)
        if (lastPssAt == 0L || now - lastPssAt >= 30_000) {
            pss = runCatching { Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }.totalPss.toLong() * 1024 }.getOrDefault(0)
            lastPssAt = now
        }
        val turn = runCatching { Libbox.getVKTurnPrototypeStats(session) }.getOrNull()
        val runtime = runCatching { Libbox.androidRuntimeStats() }.getOrNull()
        val row = listOf((now - started) / 1000.0, state.mode.name, state.phase.name, generation,
            network, turn?.activeConnections ?: 0, turn?.txBytes ?: 0, turn?.rxBytes ?: 0,
            state.txBytes, state.rxBytes, rss, pss, runtime?.heapBytes ?: 0, runtime?.goroutines ?: 0).joinToString(",") + "\n"
        runCatching {
            if (csv != null && csv!!.length() >= 4 * 1024 * 1024) {
                output?.close()
                csv = File(directory, "vpn-${System.currentTimeMillis()}.csv")
                output = FileOutputStream(csv!!)
                output!!.write(("elapsed_seconds,mode,phase,generation,network,turn_active_sessions,wg_transport_tx_bytes,wg_transport_rx_bytes,user_tx_bytes,user_rx_bytes,rss_bytes,pss_bytes,go_heap_bytes,goroutines\n").toByteArray())
                directory.listFiles()?.filter { it.extension == "csv" }?.sortedByDescending { it.name }?.drop(3)?.forEach { it.delete() }
            }
            output?.write(row.toByteArray())
            output?.flush()
        }
        return MemorySample(rss, if (now - lastPssAt <= 35_000) pss else 0, now, lastPssAt)
    }

    @Synchronized fun finish() { runCatching { output?.flush(); output?.close() }; output = null }

    companion object {
        fun latest(context: Context): File? = File(context.filesDir, "diagnostics").listFiles()
            ?.filter { it.extension == "csv" }?.maxByOrNull { it.name }
    }
}
