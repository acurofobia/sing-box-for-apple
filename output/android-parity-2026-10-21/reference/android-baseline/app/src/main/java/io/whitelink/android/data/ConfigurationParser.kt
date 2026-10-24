package io.whitelink.android.data

import java.net.URI
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

object ConfigurationParser {
    const val MAX_CONFIG_BYTES = 8 * 1024 * 1024
    private const val MAX_TURN_BYTES = 128 * 1024
    private val uuidPattern = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    /** Return the one selected outbound, retaining all unknown core-supported fields. */
    fun parseVless(text: String, validateCore: (String) -> Unit = {}): String? {
        try {
            val root = StrictJson.objectValue(text, MAX_CONFIG_BYTES)
            val nodes: List<JSONObject> = if (root.opt("type") == "vless") {
                listOf(root)
            } else {
                val outbounds = root.opt("outbounds") as? JSONArray ?: invalidVless()
                buildList {
                    for (index in 0 until outbounds.length()) {
                        val node = outbounds.opt(index) as? JSONObject ?: invalidVless()
                        if (node.opt("type") == "vless") add(node)
                    }
                }
            }
            if (nodes.isEmpty()) return null
            val preferred = nodes.filter { it.opt("tag") == "R3-N1" }
            val candidates = preferred.ifEmpty { nodes }
            if (candidates.size != 1) invalidVless()
            val node = candidates.single()
            val server = node.opt("server") as? String ?: invalidVless()
            if (server.isBlank() || hasControls(server) || server.any { it.isWhitespace() || it in "/\\?#@" }) invalidVless()
            integer(node.opt("server_port"), 1..65535) ?: invalidVless()
            val uuid = node.opt("uuid") as? String ?: invalidVless()
            if (!uuidPattern.matches(uuid)) invalidVless()
            UUID.fromString(uuid)
            if (node.has("detour")) invalidVless()
            rejectFilePaths(node)
            val result = node.toString()
            try { validateCore(result) } catch (_: Exception) { invalidVless() }
            return result
        } catch (_: ProfileException) {
            invalidVless()
        } catch (_: Exception) {
            invalidVless()
        }
    }

    /** Core bootstrap JSON compatible with the local iOS libbox integration. */
    fun parseTurn(text: String, deviceId: String): String {
        try {
            val link = text.trim()
            if (link.toByteArray(Charsets.UTF_8).size > MAX_TURN_BYTES) invalidTurn()
            val settings = if (link.startsWith("wdtt://", ignoreCase = true)) {
                parseWdtt(link)
            } else {
                parseVkTurnProxy(link)
            }
            return buildTurn(settings, deviceId).toString()
        } catch (error: ProfileException) {
            throw error
        } catch (_: Exception) {
            invalidTurn()
        }
    }

    /** Validate stored canonical fields without accepting an imported installation ID. */
    internal fun validateStoredTurn(text: String, deviceId: String): String {
        val root = StrictJson.objectValue(text, MAX_TURN_BYTES)
        val proxy = root.opt("proxy") as? JSONObject ?: invalidTurn()
        val settings = JSONObject()
            .put("vkLink", proxy.opt("vk_link"))
            .put("peerAddress", proxy.opt("peer_addr"))
            .put("useWrapA", proxy.optBoolean("use_wrap_a", false))
            .put("useSrtp", proxy.optBoolean("use_srtp", false))
            .put("useUDP", proxy.opt("use_udp"))
            .put("numConnections", proxy.opt("num_conns"))
        if (proxy.has("wrap_a_password")) settings.put("wrapAPassword", proxy.opt("wrap_a_password"))
        if (proxy.has("turn_server")) {
            val host = proxy.opt("turn_server") as? String ?: invalidTurn()
            val port = proxy.opt("turn_port") as? String ?: invalidTurn()
            settings.put("turnServerOverride", if (':' in host) "[$host]:$port" else "$host:$port")
        }
        val wg = root.opt("wireguard") as? JSONObject
        if (wg != null) {
            settings.put("privateKey", wg.opt("private_key"))
            settings.put("peerPublicKey", wg.opt("public_key"))
            settings.put("tunnelAddress", wg.opt("address"))
            val psk = wg.opt("preshared_key")
            if (psk is String && psk.isNotEmpty()) settings.put("presharedKey", psk)
        }
        return buildTurn(settings, deviceId).toString()
    }

    private fun parseWdtt(link: String): JSONObject {
        val fields = link.substring(7).split(':', limit = 6)
        if (fields.size != 6 || fields[4].isEmpty()) invalidTurn()
        val port = fields[1].toIntOrNull()?.takeIf { it in 1..65535 } ?: invalidTurn()
        val firstHash = fields[5].substringBefore('#').substringBefore(',')
        val prefixes = listOf("https://vk.ru/call/join/", "https://vk.com/call/join/", "https://vk.me/join/")
        val prefix = prefixes.firstOrNull { firstHash.startsWith(it, ignoreCase = true) }
        val hash = if (prefix == null) firstHash else firstHash.substring(prefix.length)
        if (hash.isEmpty() || hash.any { it in "/?#" } || hasControls(hash)) invalidTurn()
        return JSONObject().put("vkLink", "https://vk.ru/call/join/$hash")
            .put("peerAddress", "${fields[0]}:$port")
            .put("useWrapA", true).put("wrapAPassword", fields[4])
    }

    private fun parseVkTurnProxy(link: String): JSONObject {
        val uri = URI(link)
        if (!uri.scheme.equals("vkturnproxy", true) || !uri.host.equals("import", true) ||
            !uri.path.orEmpty().isEmpty() || uri.userInfo != null || uri.fragment != null || uri.port != -1) invalidTurn()
        val query = uri.rawQuery ?: invalidTurn()
        val values = query.split('&').map {
            val parts = it.split('=', limit = 2)
            decodeQuery(parts[0]) to decodeQuery(parts.getOrElse(1) { "" })
        }.filter { it.first == "data" }
        if (values.size != 1) invalidTurn()
        val encoded = values.single().second
        if (encoded.length > 90_000 || encoded.isEmpty() || !Regex("[A-Za-z0-9_+/=-]+").matches(encoded)) invalidTurn()
        val bytes = try { BinaryEncoding.decodeBase64(encoded) } catch (_: Exception) { invalidTurn() }
        val root = StrictJson.objectValue(decodeUtf8(bytes), MAX_TURN_BYTES)
        if (integer(root.opt("version"), 1..1) != 1 || root.opt("type") != "connection") invalidTurn()
        return root.opt("settings") as? JSONObject ?: invalidTurn()
    }

    private fun decodeQuery(value: String): String {
        // URLDecoder changes unescaped '+' into a space, corrupting normal base64.
        return java.net.URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
    }

    private fun buildTurn(settings: JSONObject, deviceId: String): JSONObject {
        val boolNames = listOf("useWrapA", "useSrtp", "useWrap", "useWrapS", "useCsqtt", "useCookieAuth", "useUDP")
        boolNames.forEach { name ->
            if (settings.has(name) && !settings.isNull(name) && settings.opt(name) !is Boolean) invalidTurn()
        }
        val wrap = settings.opt("useWrapA") == true
        if (!wrap && settings.opt("useSrtp") != true) unsupportedTurn()
        if (!wrap) throw ProfileException("Android поддерживает VK TURN SRTP-WRAP-A с получением WireGuard-параметров у шлюза. Импортируйте WRAP-A ссылку.")
        if (listOf("useWrap", "useWrapS", "useCsqtt", "useCookieAuth").any { settings.opt(it) == true }) unsupportedTurn()
        val stringNames = listOf("privateKey", "peerPublicKey", "tunnelAddress", "vkLink", "peerAddress", "presharedKey", "dnsServers", "turnServerOverride", "wrapAPassword")
        stringNames.forEach { name ->
            if (settings.has(name) && !settings.isNull(name)) {
                val value = settings.opt(name) as? String ?: invalidTurn()
                if (hasControls(value)) invalidTurn()
            }
        }
        val vkLink = requiredString(settings, "vkLink")
        val vkUrl = URI(vkLink)
        val allowedPath = when (vkUrl.host?.lowercase()) {
            "vk.me" -> "/join/"
            "vk.ru", "vk.com" -> "/call/join/"
            else -> invalidTurn()
        }
        if (vkUrl.scheme != "https" || vkUrl.userInfo != null || vkUrl.fragment != null ||
            vkUrl.port !in listOf(-1, 443) || !vkUrl.path.orEmpty().startsWith(allowedPath) ||
            vkUrl.path.orEmpty().length <= allowedPath.length) invalidTurn()
        val peer = requiredString(settings, "peerAddress")
        endpoint(peer)
        val count = if (!settings.has("numConnections") || settings.isNull("numConnections")) 30 else
            integer(settings.opt("numConnections"), 1..50) ?: invalidTurn()
        val proxy = JSONObject().put("vk_link", vkLink).put("peer_addr", peer)
            .put("use_srtp", !wrap).put("use_dtls", !wrap)
            .put("use_udp", settings.opt("useUDP") == true).put("num_conns", count)
            .put("use_cookie_auth", false)
        val result = JSONObject().put("proxy", proxy)
        if (wrap) {
            val password = requiredString(settings, "wrapAPassword")
            if (deviceId.isBlank() || hasControls(deviceId)) invalidTurn()
            proxy.put("use_wrap_a", true).put("wrap_a_password", password).put("device_id", deviceId)
        } else {
            val privateKey = requiredString(settings, "privateKey")
            val publicKey = requiredString(settings, "peerPublicKey")
            if (!validKey(privateKey) || !validKey(publicKey)) invalidTurn()
            val address = requiredString(settings, "tunnelAddress")
            if (!validTunnelAddress(address)) invalidTurn()
            val wg = JSONObject().put("private_key", privateKey).put("public_key", publicKey)
                .put("address", address).put("mtu", 1280)
            val psk = settings.opt("presharedKey") as? String
            if (psk != null) {
                if (!validKey(psk)) invalidTurn()
                wg.put("preshared_key", psk)
            }
            result.put("wireguard", wg)
        }
        val turnOverride = settings.opt("turnServerOverride") as? String
        if (!turnOverride.isNullOrEmpty()) {
            val turn = endpoint(turnOverride)
            proxy.put("turn_server", turn.host.removePrefix("[").removeSuffix("]"))
            proxy.put("turn_port", turn.port.toString())
        }
        return result
    }

    private fun endpoint(value: String): URI {
        val endpoint = URI("udp://$value")
        if (endpoint.host.isNullOrBlank() || endpoint.port !in 1..65535 || endpoint.userInfo != null ||
            !endpoint.path.orEmpty().isEmpty() || endpoint.query != null || endpoint.fragment != null) invalidTurn()
        return endpoint
    }

    private fun validKey(value: String): Boolean = try {
        Regex("[A-Za-z0-9+/]{43}=").matches(value) && BinaryEncoding.decodeBase64(value).size == 32
    } catch (_: Exception) { false }

    private fun validTunnelAddress(value: String): Boolean {
        val pieces = value.split('/')
        if (pieces.size != 2 || pieces[1].toIntOrNull() !in 1..32) return false
        val octets = pieces[0].split('.')
        return octets.size == 4 && octets.all { it.isNotEmpty() && it.all { char -> char in '0'..'9' } && it.toIntOrNull() in 0..255 }
    }

    private fun requiredString(root: JSONObject, key: String): String =
        (root.opt(key) as? String)?.takeIf { it.isNotEmpty() } ?: invalidTurn()

    private fun rejectFilePaths(value: Any?) {
        when (value) {
            is JSONObject -> {
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    if (key.endsWith("_path") || key.endsWith("Path")) invalidVless()
                    rejectFilePaths(value.opt(key))
                }
            }
            is JSONArray -> for (index in 0 until value.length()) rejectFilePaths(value.opt(index))
        }
    }

    internal fun integer(value: Any?, range: IntRange): Int? {
        if (value !is Number) return null
        val number = value.toDouble()
        if (!number.isFinite() || number != number.toInt().toDouble()) return null
        return number.toInt().takeIf { it in range }
    }

    internal fun decodeUtf8(bytes: ByteArray): String = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    } catch (_: Exception) { throw ProfileException("Ответ содержит некорректный UTF-8.") }

    private fun hasControls(value: String): Boolean = value.any { it.code < 0x20 || it.code == 0x7f }
    private fun invalidVless(): Nothing = throw ProfileException("Нужен JSON с одним VLESS-сервером или единственным сервером R3-N1, без detour.")
    private fun invalidTurn(): Nothing = throw ProfileException("В ссылке VK TURN отсутствуют обязательные поля или одно из них некорректно.")
    private fun unsupportedTurn(): Nothing = throw ProfileException("Поддерживается анонимный режим VK TURN SRTP-WRAP-A.")
}
