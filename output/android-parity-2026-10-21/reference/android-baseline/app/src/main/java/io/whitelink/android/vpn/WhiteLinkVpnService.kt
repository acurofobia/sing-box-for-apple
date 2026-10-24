/*
 * WhiteLink VPN platform integration.
 * Derived from SagerNet/sing-box-for-android VPNService, BoxService,
 * PlatformInterfaceWrapper and DefaultNetworkMonitor at the vendored revision.
 * Copyright (C) SagerNet contributors. SPDX-License-Identifier: GPL-3.0-or-later
 * Platform-independent TURN integration follows the local iOS prototype.
 */
package io.whitelink.android.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.system.OsConstants
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import go.Seq
import io.nekohasekai.libbox.*
import io.whitelink.android.data.ProfileStore
import io.whitelink.android.data.SelectedMode
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface as JavaNetworkInterface
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.min
import io.nekohasekai.libbox.NetworkInterface as BoxNetworkInterface
import io.nekohasekai.libbox.Notification as BoxNotification

/** Only this service opens a TUN or owns a CommandServer. No IP packets cross JNI. */
class WhiteLinkVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object {
        const val CONNECT = "io.whitelink.android.CONNECT"
        const val STOP = "io.whitelink.android.STOP"
        private const val CHANNEL = "vpn"
        private const val NOTIFICATION = 1
        private val setupLock = Any()
        @Volatile private var setupComplete = false
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val changes = Channel<Unit>(Channel.CONFLATED)
    private val ingress = Mutex()
    private val gate = Any()
    private val epoch = AtomicLong()
    @Volatile private var desired = false
    @Volatile private var desiredMode = SelectedMode.VLESS
    @Volatile internal var cleanupPending = false
        private set
    @Volatile private var destroyed = false
    @Volatile private var runtimeClosing = true
    @Volatile private var idle = false
    @Volatile private var underlying: Network? = null
    private val lostNetworks = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<Network, Boolean>())
    @Volatile private var linkSignature = ""
    @Volatile private var interfaceListener: InterfaceUpdateListener? = null
    @Volatile private var commandServer: CommandServer? = null
    private var commandClient: CommandClient? = null
    private var tun: ParcelFileDescriptor? = null
    private var sessionID = 0L
    private var runningEpoch = 0L
    private var sampleJob: Job? = null
    private var watchdog: Job? = null
    private lateinit var store: ProfileStore
    private lateinit var diagnostics: Diagnostics
    private lateinit var connectivity: ConnectivityManager
    private var monitorRegistered = false
    private var idleRegistered = false
    private var worker: Job? = null

    override fun onCreate() {
        super.onCreate()
        Seq.setContext(applicationContext)
        store = ProfileStore(this)
        diagnostics = Diagnostics(this)
        connectivity = getSystemService(ConnectivityManager::class.java)
        VpnController.service = this
        worker = scope.launch {
            for (ignored in changes) {
                // Wait for the cancellation submitted before this reconciliation.
                ingress.withLock { }
                try {
                    reconcile()
                } catch (error: Exception) {
                    desired = false
                    closeRuntime()
                    VpnController.mutableState.update { it.copy(phase = VpnPhase.ERROR,
                        error = "Не удалось запустить VPN. Проверьте настройки и разрешение.") }
                    cleanupPending = true
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            requestStop()
            return START_NOT_STICKY
        }
        showNotification("Подготовка…") // Must precede VK bootstrap / any blocking native call.
        if (!desired) {
            runCatching { desiredMode = store.selectedMode() }.onFailure {
                VpnController.mutableState.update { it.copy(phase = VpnPhase.ERROR, error = "Требуется повторный импорт конфигураций.") }
                cleanupPending = true
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            desired = true
            registerMonitors()
            submitChange()
        }
        return START_NOT_STICKY
    }

    internal fun requestStop() {
        desired = false
        VpnController.mutableState.update { it.copy(phase = VpnPhase.STOPPING, error = null, rssBytes = 0, pssBytes = 0,
            txSpeed = 0, rxSpeed = 0, allocations = 0) }
        submitChange()
    }

    internal fun requestMode(mode: SelectedMode) {
        if (cleanupPending || destroyed || mode == desiredMode) return
        desiredMode = mode
        desired = true
        VpnController.mutableState.update { it.copy(phase = VpnPhase.STOPPING, error = null,
            txSpeed = 0, rxSpeed = 0, allocations = 0, rssBytes = 0, pssBytes = 0) }
        submitChange()
    }

    /** Invalidate synchronously; native cancel is separate from the serialized startup worker. */
    private fun submitChange() {
        VpnController.mutableState.update { old ->
            if (old.phase == VpnPhase.CONNECTED) old.copy(phase = VpnPhase.RECONNECTING,
                txSpeed = 0, rxSpeed = 0, allocations = 0, rssBytes = 0, pssBytes = 0) else old
        }
        val token = synchronized(gate) {
            val value = epoch.incrementAndGet()
            Libbox.invalidateVKTurnPrototype() // generation only; no socket/worker waits
            value
        }
        cleanupPending = commandServer != null || VpnController.state.value.phase == VpnPhase.BOOTSTRAPPING ||
            VpnController.state.value.phase == VpnPhase.CONNECTING || VpnController.state.value.phase == VpnPhase.STOPPING
        watchdog?.cancel()
        if (cleanupPending) watchdog = scope.launch {
            delay(15_000)
            if (token == epoch.get() && cleanupPending) {
                desired = false
                VpnController.mutableState.update { it.copy(phase = VpnPhase.ERROR,
                    error = "VPN не остановился за 15 секунд. Дождитесь освобождения ресурсов.", rssBytes = 0, pssBytes = 0) }
                diagnostics.log("[VPN] Превышено время остановки; новый core не запускается")
            }
        }
        scope.launch {
            ingress.withLock {
                if (token != epoch.get()) return@withLock
                // Epoch invalidation already acquired the short begin gate on
                // the caller. Native cleanup must never hold that gate.
                Libbox.cancelVKTurnPrototype()
                // StartedService.CloseService interrupts a core currently starting
                // before waiting on its lifecycle lock (upstream SFA behavior).
                runCatching { commandServer?.closeService() }
                changes.trySend(Unit)
            }
        }
    }

    private suspend fun reconcile() {
        val token = epoch.get()
        if (refuseRestartIfUnclosed(closeRuntime())) return
        cleanupPending = false
        watchdog?.cancel()
        if (destroyed) return
        if (!desired) {
            val previousError = VpnController.state.value.error
            VpnController.mutableState.update { it.copy(
                phase = if (previousError == null) VpnPhase.DISCONNECTED else VpnPhase.ERROR,
                txSpeed = 0, rxSpeed = 0, rssBytes = 0, pssBytes = 0, allocations = 0) }
            cleanupPending = true
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        val mode = desiredMode
        var attempt = 0
        while (desired && token == epoch.get() && !destroyed) {
            if (idle) {
                setPhase(VpnPhase.RECONNECTING, mode)
                return // The wake callback resumes the same selected mode.
            }
            if (underlying == null) {
                setPhase(VpnPhase.WAITING_FOR_NETWORK, mode)
                return
            }
            try {
                startRuntime(mode, token)
                return
            } catch (cancelled: CancellationException) {
                refuseRestartIfUnclosed(closeRuntime())
                return
            } catch (failure: Exception) {
                val rawMessage = failure.message ?: "Ошибка сетевого ядра"
                val message = diagnostics.redact(rawMessage)
                diagnostics.log("[VPN] $message")
                if (refuseRestartIfUnclosed(closeRuntime())) return
                if (token != epoch.get() || !desired || destroyed) return
                if (underlying == null) {
                    setPhase(VpnPhase.WAITING_FOR_NETWORK, mode)
                    return
                }
                val permanent = listOf("wrong_password", "expired", "device_mismatch", "invalid", "unsupported",
                    "не импортирована", "повторный импорт", "permission", "protocol", "missing",
                    "captcha", "requires WRAP-A", "inconsistent", "no previous").any { rawMessage.contains(it, true) }
                if (permanent || attempt >= 6) {
                    desired = false
                    VpnController.mutableState.update { it.copy(phase = VpnPhase.ERROR, error = friendlyError(rawMessage),
                        txSpeed = 0, rxSpeed = 0, rssBytes = 0, pssBytes = 0, allocations = 0) }
                    cleanupPending = true
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return
                }
                setPhase(VpnPhase.RECONNECTING, mode)
                delay(min(30L, 1L shl attempt++) * 1000)
            }
        }
    }

    private fun friendlyError(message: String): String = when {
        message.contains("captcha", true) -> "VK запросил ручную капчу. Интерактивная капча пока не поддерживается этой тестовой сборкой."
        message.contains("wrong_password", true) -> "Неверный пароль VK TURN."
        message.contains("expired", true) -> "Срок доступа VK TURN истёк."
        message.contains("device_mismatch", true) -> "VK TURN доступ привязан к другому устройству."
        message.contains("permission", true) -> "Разрешите системное подключение VPN."
        message.contains("bootstrap", true) -> "Не удалось получить параметры VK TURN. Проверьте сеть и ссылку."
        else -> diagnostics.redact(message).take(300)
    }

    private fun ensureCurrent(token: Long) {
        if (token != epoch.get() || !desired || destroyed) throw CancellationException("VPN operation cancelled")
    }

    private fun startRuntime(mode: SelectedMode, token: Long) {
        ensureCurrent(token)
        VpnController.mutableState.value = VpnUiState(phase = VpnPhase.PREPARING, mode = mode)
        setPhase(VpnPhase.PREPARING, mode)
        if (prepare(this) != null) throw IOException("missing vpn permission")
        val snapshot = store.load()
        if (!snapshot.hasMode(mode)) throw IOException("Конфигурация выбранного режима не импортирована.")
        if (snapshot.selectedMode != mode) store.selectMode(mode)
        diagnostics.start(snapshot)
        val working = File(filesDir, "core").apply { mkdirs() }
        val temporary = File(cacheDir, "core").apply { mkdirs() }
        synchronized(setupLock) {
            if (!setupComplete) {
                Libbox.setup(SetupOptions().apply {
                    basePath = working.absolutePath
                    workingPath = working.absolutePath
                    tempPath = temporary.absolutePath
                    logMaxLines = 1000
                    crashReportSource = "WhiteLink"
                    appVersion = "1"
                    appMarketingVersion = "0.1"
                    oomKillerEnabled = false
                })
                setupComplete = true
            }
        }
        val route = JSONObject(assets.open("routing.json").bufferedReader().use { it.readText() })
        val ruleSets = route.optJSONArray("rule_set") ?: JSONArray()
        val rulesDirectory = File(working, "rulesets").apply { mkdirs() }
        for (i in 0 until ruleSets.length()) {
            val rule = ruleSets.getJSONObject(i)
            val tag = rule.getString("tag")
            if (!tag.matches(Regex("[A-Za-z0-9._-]+"))) throw IOException("invalid bundled rule set")
            val file = File(rulesDirectory, "$tag.srs")
            assets.open("rulesets/$tag.srs").use { input -> file.outputStream().use { input.copyTo(it) } }
            rule.put("type", "local").put("format", "binary").put("path", file.absolutePath)
            rule.remove("url")
        }
        Libbox.setAndroidNetwork(object : AndroidNetwork {
            override fun protect(fd: Int) = protectSocket(fd)
            override fun resolve(host: String): StringIterator {
                val network = underlying ?: throw IOException("no underlying network")
                val addresses = PhysicalResolver.resolveIPv4(network, host) { token == epoch.get() && desired && !destroyed }
                if (addresses.isEmpty()) throw IOException("no IPv4 bootstrap address")
                return Strings(addresses)
            }
        })
        val coreGeneration = synchronized(gate) {
            ensureCurrent(token)
            Libbox.beginVKTurnPrototype()
        }
        runningEpoch = token
        val input = JSONObject().put("route", route).put("generation", coreGeneration)
            .put("mode", if (mode == SelectedMode.VLESS) "vless" else "vk-turn")
            .put("baseline", mode == SelectedMode.DIRECT).put("cache_path", temporary.absolutePath)
        if (mode == SelectedMode.VLESS) input.put("vless", JSONObject(snapshot.vless!!))
        if (mode == SelectedMode.TURN) {
            val turn = JSONObject(snapshot.turn!!)
            val proxy = turn.getJSONObject("proxy")
            proxy.put("device_id", store.deviceId).put("num_conns", store.connections())
            input.put("proxy", proxy)
            turn.optJSONObject("wireguard")?.let { input.put("wireguard", it) }
            ensureCurrent(token)
            setPhase(VpnPhase.BOOTSTRAPPING, mode)
        }
        startSampling(token)
        val session = Libbox.startVKTurnPrototype(input.toString())
        if (token != epoch.get() || !desired || destroyed) {
            Libbox.stopVKTurnPrototype(session.getID())
            throw CancellationException("Late bootstrap cancelled")
        }
        sessionID = session.getID()
        val config = JSONObject(session.configuration)
        // The first release captures IPv6 and rejects it; no unsupported IPv6 can bypass the VPN.
        val inbound = config.getJSONArray("inbounds").getJSONObject(0)
        val addresses = inbound.getJSONArray("address")
        if ((0 until addresses.length()).none { addresses.getString(it).contains(':') })
            addresses.put("fd00:19::1/126")
        val dnsServers = config.getJSONObject("dns").getJSONArray("servers")
        for (i in 0 until dnsServers.length()) {
            val dns = dnsServers.getJSONObject(i)
            if (dns.optString("tag") == "bootstrap") dnsServers.put(i, JSONObject().put("type", "local").put("tag", "bootstrap"))
        }
        val coreRoute = config.getJSONObject("route")
        val existing = coreRoute.optJSONArray("rules") ?: JSONArray()
        val protectedRules = JSONArray()
        if (existing.optJSONObject(0)?.optInt("ip_version") != 6)
            protectedRules.put(JSONObject().put("ip_version", 6).put("action", "reject"))
        for (i in 0 until existing.length()) protectedRules.put(existing.get(i))
        coreRoute.put("rules", protectedRules)
        ensureCurrent(token)
        setPhase(VpnPhase.CONNECTING, mode)
        val server = CommandServer(SessionHandler(token), this)
        commandServer = server
        server.start()
        Libbox.setVKTurnPrototypeLogServer(server)
        // openTun checks this epoch again. Never hold the cancellation gate across
        // a blocking core startup: stop must remain available while it runs.
        ensureCurrent(token)
        server.startOrReloadService(config.toString(), OverrideOptions())
        ensureCurrent(token)
        attachCommandClient(token)
        ensureCurrent(token)
        setPhase(VpnPhase.CONNECTED, mode)
        diagnostics.log("[VPN] Подключено: ${mode.name}" + if (mode == SelectedMode.DIRECT) "; диагностический трафик идёт напрямую" else "")
        cleanupPending = false
    }

    private fun attachCommandClient(token: Long) {
        runtimeClosing = false
        val options = CommandClientOptions().apply {
            addCommand(Libbox.CommandLog)
            addCommand(Libbox.CommandStatus)
            statusInterval = 1_000_000_000
        }
        commandClient = CommandClient(object : CommandClientHandler {
            override fun connected() { }
            override fun disconnected(message: String?) {
                if (token == epoch.get() && desired && !runtimeClosing && VpnController.state.value.phase == VpnPhase.CONNECTED) {
                    diagnostics.log("[VPN] Канал ядра отключён; восстановление текущего режима")
                    submitChange()
                }
            }
            override fun setDefaultLogLevel(level: Int) { }
            override fun clearLogs() { if (token == epoch.get()) VpnController.mutableLogs.value = emptyList() }
            override fun writeLogs(messageList: LogIterator?) {
                if (token != epoch.get()) return
                while (messageList?.hasNext() == true) diagnostics.log(messageList.next().message)
            }
            override fun writeStatus(message: StatusMessage?) {
                if (token != epoch.get() || message == null) return
                VpnController.mutableState.update { it.copy(txBytes = message.uplinkTotal, rxBytes = message.downlinkTotal,
                    txSpeed = if (it.phase == VpnPhase.CONNECTED) message.uplink else 0,
                    rxSpeed = if (it.phase == VpnPhase.CONNECTED) message.downlink else 0,
                    updatedAt = SystemClock.elapsedRealtime()) }
            }
            override fun writeGroups(message: OutboundGroupIterator?) { }
            override fun writeOutbounds(message: OutboundGroupItemIterator?) { }
            override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) { }
            override fun updateClashMode(newMode: String?) { }
            override fun writeConnectionEvents(events: ConnectionEvents?) { }
        }, options).also { it.connect() }
    }

    private fun startSampling(token: Long) {
        sampleJob?.cancel()
        sampleJob = scope.launch {
            val freshness = launch {
                while (isActive && token == epoch.get()) {
                    delay(1000)
                    val now = SystemClock.elapsedRealtime()
                    VpnController.mutableState.update { old -> old.copy(
                        rssBytes = if (now - old.rssUpdatedAt > 5000) 0 else old.rssBytes,
                        pssBytes = if (now - old.pssUpdatedAt > 35_000) 0 else old.pssBytes) }
                }
            }
            try {
            while (isActive && token == epoch.get()) {
                val state = VpnController.state.value
                val memory = diagnostics.sample(state, token, networkName(), sessionID)
                val transport = runCatching { Libbox.getVKTurnPrototypeStats(sessionID) }.getOrNull()
                val allocations = transport?.activeConnections ?: 0
                if (token == epoch.get() && desired && !transport?.error.isNullOrBlank()) {
                    desired = false
                    VpnController.mutableState.update { it.copy(phase = VpnPhase.STOPPING,
                        error = friendlyError(transport!!.error), rssBytes = 0, pssBytes = 0) }
                    submitChange()
                    return@launch
                }
                if (token == epoch.get()) VpnController.mutableState.update { it.copy(
                    rssBytes = memory.rss, pssBytes = memory.pss, allocations = allocations,
                    rssUpdatedAt = memory.rssAt, pssUpdatedAt = memory.pssAt) }
                runCatching {
                    val logs = JSONArray(Libbox.readAndroidLogs())
                    // Once the command stream exists it is the single source of
                    // core/transport logs. Drain the bootstrap queue without replay.
                    if (commandClient == null) for (i in 0 until logs.length())
                        if (token == epoch.get()) diagnostics.log(logs.getString(i))
                }
                delay(1000)
            }
            } finally { freshness.cancel() }
        }
    }

    private fun closeRuntime(): Boolean {
        runtimeClosing = true
        sampleJob?.cancel()
        sampleJob = null
        runCatching { Libbox.cancelVKTurnPrototype() }
        runCatching { Libbox.stopVKTurnPrototype(sessionID) }
        sessionID = 0
        runCatching { commandClient?.disconnect() }
        commandClient = null
        runCatching { Libbox.setVKTurnPrototypeLogServer(null) }
        runCatching { commandServer?.closeService() }
        runCatching { commandServer?.close() }
        commandServer = null
        runCatching { tun?.close() }
        tun = null
        runCatching { Libbox.setAndroidNetwork(null) }
        runCatching { diagnostics.sample(VpnController.state.value.copy(phase = VpnPhase.STOPPING), runningEpoch, networkName(), 0) }
        diagnostics.finish()
        return runCatching { Libbox.verifyAndroidTransportStopped() }.getOrDefault(false)
    }

    private fun refuseRestartIfUnclosed(stopped: Boolean): Boolean {
        if (stopped) return false
        desired = false
        cleanupPending = true
        watchdog?.cancel()
        VpnController.mutableState.update { it.copy(phase = VpnPhase.ERROR,
            error = "Предыдущий транспорт ещё останавливается. Новое подключение заблокировано.",
            rssBytes = 0, pssBytes = 0, txSpeed = 0, rxSpeed = 0, allocations = 0) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        return true
    }

    private fun setPhase(phase: VpnPhase, mode: SelectedMode) {
        val suspended = phase == VpnPhase.WAITING_FOR_NETWORK || phase == VpnPhase.RECONNECTING || phase == VpnPhase.STOPPING
        VpnController.mutableState.update { it.copy(phase = phase, mode = mode, error = null,
            txSpeed = if (suspended) 0 else it.txSpeed,
            rxSpeed = if (suspended) 0 else it.rxSpeed,
            allocations = if (suspended) 0 else it.allocations,
            rssBytes = if (suspended) 0 else it.rssBytes,
            pssBytes = if (suspended) 0 else it.pssBytes) }
        showNotification(when (phase) {
            VpnPhase.CONNECTED -> if (mode == SelectedMode.DIRECT) "Диагностика: напрямую" else "Подключено · ${mode.name}"
            VpnPhase.WAITING_FOR_NETWORK -> "Ожидание сети"
            VpnPhase.RECONNECTING -> "Восстановление · ${mode.name}"
            VpnPhase.BOOTSTRAPPING -> "Получение параметров VK TURN"
            else -> "Подключение · ${mode.name}"
        })
    }

    private fun showNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(CHANNEL, "VPN", NotificationManager.IMPORTANCE_LOW))
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val stop = PendingIntent.getService(this, 2, Intent(this, WhiteLinkVpnService::class.java).setAction(STOP), flags)
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(io.whitelink.android.R.drawable.ic_whitelink).setContentTitle("WhiteLink VPN")
            .setContentText(text).setOnlyAlertOnce(true).setOngoing(true).setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(0, "Отключить", stop)
        if (launch != null) builder.setContentIntent(PendingIntent.getActivity(this, 1, launch, flags))
        startForeground(NOTIFICATION, builder.build())
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { lostNetworks.remove(network); refreshNetwork() }
        override fun onLost(network: Network) {
            if (lostNetworks.size >= 128) lostNetworks.clear()
            lostNetworks.add(network)
            refreshNetwork()
        }
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = refreshNetwork()
        override fun onLinkPropertiesChanged(network: Network, properties: android.net.LinkProperties) {
            if (network != underlying) return
            val signature = properties.interfaceName + ":" + properties.linkAddresses.joinToString() + ":" + properties.dnsServers.joinToString()
            val changed = linkSignature.isNotEmpty() && linkSignature != signature
            linkSignature = signature
            publishInterface()
            if (changed && desired) submitChange()
        }
    }

    private fun physicalNetworks(): List<Network> = connectivity.allNetworks.filter {
        val c = connectivity.getNetworkCapabilities(it)
        !lostNetworks.contains(it) && c?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) == true &&
            c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    private fun updateNetwork() {
        val available = physicalNetworks()
        val active = connectivity.activeNetwork?.takeIf { available.contains(it) }
        // A network can disappear between Binder reads during Wi-Fi/mobile
        // handover. Capture nullable capabilities instead of force-unwrapping.
        val chosen = active ?: available.mapNotNull { n ->
            val c = connectivity.getNetworkCapabilities(n) ?: return@mapNotNull null
            n to ((if (c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 10 else 0) +
                (if (c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) 2 else 1))
        }.maxByOrNull { it.second }?.first
        val changed = chosen != underlying
        if (changed) linkSignature = ""
        underlying = chosen
        runCatching { setUnderlyingNetworks(chosen?.let { arrayOf(it) }) }
        publishInterface()
        if (changed && desired) submitChange()
    }

    private fun refreshNetwork() {
        runCatching { updateNetwork() }.onFailure {
            underlying = null
            runCatching { setUnderlyingNetworks(null) }
            if (desired && !destroyed) submitChange()
        }
    }

    private fun networkName(): String = underlying?.let {
        val c = connectivity.getNetworkCapabilities(it)
        when {
            c?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "wifi"
            c?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "mobile"
            else -> "other"
        }
    } ?: "none"

    private fun publishInterface() {
        val listener = interfaceListener ?: return
        val n = underlying
        val properties = n?.let { connectivity.getLinkProperties(it) }
        val name = properties?.interfaceName
        val index = runCatching { JavaNetworkInterface.getByName(name)?.index }.getOrNull() ?: -1
        val caps = n?.let { connectivity.getNetworkCapabilities(it) }
        runCatching { listener.updateDefaultInterface(name ?: "", index,
            caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false, false) }
        runCatching { listener.updateNetworkPath(networkName()) }
    }

    private val idleReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED) return
            scope.launch {
                idle = getSystemService(PowerManager::class.java).isDeviceIdleMode
                if (idle) {
                    runCatching { commandServer?.pause() }
                    if (desired) VpnController.mutableState.update { it.copy(phase = VpnPhase.RECONNECTING, txSpeed = 0, rxSpeed = 0) }
                } else {
                    runCatching { commandServer?.wake() }
                    if (desired) submitChange() // Rebuild TURN allocations after wake.
                }
            }
        }
    }

    private fun registerMonitors() {
        idle = getSystemService(PowerManager::class.java).isDeviceIdleMode
        if (!monitorRegistered) {
            connectivity.registerNetworkCallback(NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), networkCallback)
            monitorRegistered = true
            updateNetwork()
        }
        if (!idleRegistered) {
            ContextCompat.registerReceiver(this, idleReceiver, IntentFilter(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
            idleRegistered = true
        }
    }

    private fun protectSocket(fd: Int) {
        if (!protect(fd)) throw IOException("VPN socket protection failed")
        val network = underlying ?: throw IOException("no underlying network")
        ParcelFileDescriptor.fromFd(fd).use { network.bindSocket(it.fileDescriptor) }
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun autoDetectInterfaceControl(fd: Int) = protectSocket(fd)
    override fun openTun(options: TunOptions): Int {
        ensureCurrent(runningEpoch)
        if (prepare(this) != null) throw IOException("missing vpn permission")
        val builder = Builder().setSession("WhiteLink VPN").setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
        var has4 = false
        val inet4 = options.inet4Address
        while (inet4.hasNext()) { val a = inet4.next(); builder.addAddress(a.address(), a.prefix()); has4 = true }
        val inet6 = options.inet6Address
        var has6 = false
        while (inet6.hasNext()) { val a = inet6.next(); builder.addAddress(a.address(), a.prefix()); has6 = true }
        if (!has4) builder.addAddress("172.19.0.1", 30)
        if (!has6) builder.addAddress("fd00:19::1", 126)
        builder.addRoute("0.0.0.0", 0).addRoute("::", 0)
        if (options.dnsMode.value != Libbox.DNSModeDisabled) {
            val dns = options.dnsServerAddress
            while (dns.hasNext()) builder.addDnsServer(dns.next())
        }
        underlying?.let { builder.setUnderlyingNetworks(arrayOf(it)) }
        val descriptor = builder.establish() ?: throw IOException("VPN permission revoked")
        if (runningEpoch != epoch.get() || !desired) { descriptor.close(); throw IOException("VPN startup cancelled") }
        tun = descriptor
        return descriptor.fd
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < 29
    override fun findConnectionOwner(ipProtocol: Int, sourceAddress: String, sourcePort: Int,
        destinationAddress: String, destinationPort: Int): ConnectionOwner {
        if (Build.VERSION.SDK_INT < 29) throw IOException("connection owner unavailable")
        val uid = connectivity.getConnectionOwnerUid(ipProtocol, InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort))
        if (uid == Process.INVALID_UID) throw IOException("connection owner unavailable")
        val packages = packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        return ConnectionOwner().apply { userId = uid; userName = packages.firstOrNull() ?: ""; setAndroidPackageNames(Strings(packages)) }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) { interfaceListener = listener; publishInterface() }
    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) { interfaceListener = null }
    override fun getInterfaces(): NetworkInterfaceIterator {
        val interfaces = physicalNetworks().mapNotNull { network ->
            val properties = connectivity.getLinkProperties(network) ?: return@mapNotNull null
            val name = properties.interfaceName ?: return@mapNotNull null
            val native = JavaNetworkInterface.getByName(name) ?: return@mapNotNull null
            val caps = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
            BoxNetworkInterface().apply {
                this.name = name; index = native.index; mtu = runCatching { native.mtu }.getOrDefault(1280)
                // Android's link-local IPv6 hostAddress includes a %scope, which
                // is not a valid netip prefix. Upstream SFA removes that scope.
                addresses = Strings(native.interfaceAddresses.mapNotNull {
                    val address = it.address.hostAddress?.substringBefore('%') ?: return@mapNotNull null
                    "$address/${it.networkPrefixLength}"
                })
                dnsServer = Strings(properties.dnsServers.mapNotNull { it.hostAddress })
                gateway = Strings(properties.routes.filter { it.destination.prefixLength == 0 }.mapNotNull { it.gateway?.hostAddress })
                metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                type = when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                    else -> Libbox.InterfaceTypeOther
                }
                flags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                if (native.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
                if (native.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
                if (native.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
            }
        }.iterator()
        return object : NetworkInterfaceIterator {
            override fun hasNext(): Boolean = interfaces.hasNext()
            override fun next(): BoxNetworkInterface = interfaces.next()
        }
    }

    override fun localDNSTransport(): LocalDNSTransport = PhysicalResolver(
        network = { underlying }, current = { desired && !destroyed && runningEpoch == epoch.get() })
    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun readWIFIState(): WIFIState = WIFIState("", "")
    override fun clearDNSCache() { }
    override fun sendNotification(notification: BoxNotification?) {
        if (notification != null) diagnostics.log("[Core] ${notification.title}: ${notification.body}")
    }
    override fun cancelNotification(identifier: String?, typeID: Int) { }
    override fun startNeighborMonitor(listener: NeighborUpdateListener?) { }
    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) { }
    override fun registerMyInterface(name: String?) { }
    override fun usePlatformShell(): Boolean = false
    override fun checkPlatformShell() { throw IOException("platform shell unsupported") }
    override fun openShellSession(user: PlatformUser?, command: String?, environ: StringIterator?, term: String?, rows: Int, cols: Int): ShellSession = throw IOException("platform shell unsupported")
    override fun lookupUser(username: String?): PlatformUser = throw IOException("platform shell unsupported")
    override fun lookupSFTPServer(): String = throw IOException("SFTP unsupported")
    override fun readSystemSSHHostKey(): String = throw IOException("SSH unsupported")
    override fun tailscaleHostname(): String = "WhiteLink Android"
    override fun usePlatformBridge(): Boolean = false
    override fun createBridge(options: BridgeOptions?): BridgeSession = throw IOException("platform bridge unsupported")
    override fun serviceStop() { requestStop() }
    override fun serviceReload() { if (desired) submitChange() }
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()
    override fun setSystemProxyEnabled(enabled: Boolean) { if (enabled) throw IOException("system HTTP proxy unsupported") }
    override fun triggerNativeCrash() { throw IOException("debug crash disabled") }
    override fun writeDebugMessage(message: String?) { if (message != null) diagnostics.log(message) }
    override fun connectSSHAgent(): Int = -1

    /** Late callbacks from an old command server cannot affect the new session. */
    private inner class SessionHandler(private val token: Long) : CommandServerHandler {
        override fun serviceStop() { if (token == epoch.get()) requestStop() }
        override fun serviceReload() { if (token == epoch.get() && desired) submitChange() }
        override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()
        override fun setSystemProxyEnabled(enabled: Boolean) { if (enabled) throw IOException("system HTTP proxy unsupported") }
        override fun triggerNativeCrash() { throw IOException("debug crash disabled") }
        override fun writeDebugMessage(message: String?) { if (token == epoch.get() && message != null) diagnostics.log(message) }
        override fun connectSSHAgent(): Int = -1
    }

    override fun onRevoke() { requestStop(); super.onRevoke() }
    override fun onDestroy() {
        destroyed = true
        desired = false
        cleanupPending = true
        synchronized(gate) { epoch.incrementAndGet(); Libbox.invalidateVKTurnPrototype() }
        if (monitorRegistered) runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
        if (idleRegistered) runCatching { unregisterReceiver(idleReceiver) }
        monitorRegistered = false; idleRegistered = false
        // Keep cleanup outside main and let any ongoing native bootstrap leave first.
        scope.launch {
            ingress.withLock { Libbox.cancelVKTurnPrototype() }
            runCatching { commandServer?.closeService() }
            changes.close()
            worker?.join()
            closeRuntime()
            while (!Libbox.verifyAndroidTransportStopped()) delay(1000)
            cleanupPending = false
            if (VpnController.service === this@WhiteLinkVpnService) {
                VpnController.mutableState.update { it.copy(phase = if (it.error == null) VpnPhase.DISCONNECTED else VpnPhase.ERROR,
                    txSpeed = 0, rxSpeed = 0, rssBytes = 0, pssBytes = 0, allocations = 0,
                    updatedAt = SystemClock.elapsedRealtime()) }
                VpnController.service = null
            }
            scope.cancel()
        }
        super.onDestroy()
    }

    private class Strings(private val items: List<String>) : StringIterator {
        private val iterator = items.iterator()
        override fun len(): Int = items.size
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): String = iterator.next()
    }
}
