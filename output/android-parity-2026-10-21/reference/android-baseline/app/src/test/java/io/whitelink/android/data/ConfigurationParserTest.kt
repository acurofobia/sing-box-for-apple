package io.whitelink.android.data

import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ConfigurationParserTest {
    private fun node(tag: String? = null): JSONObject = JSONObject()
        .put("type", "vless").put("server", "vpn.example.test").put("server_port", 443)
        .put("uuid", "11111111-1111-4111-8111-111111111111")
        .apply { if (tag != null) put("tag", tag) }

    @Test fun preservesRealityVisionTransportAndUnknownFields() {
        val input = node().put("flow", "xtls-rprx-vision")
            .put("tls", JSONObject().put("enabled", true).put("reality", JSONObject().put("enabled", true).put("public_key", "opaque")))
            .put("future_parameter", JSONObject().put("nested", listOf(1, "two")))
        var validated: String? = null
        val result = ConfigurationParser.parseVless(input.toString()) { validated = it }!!
        val output = JSONObject(result)
        assertEquals(input.toString(), result)
        assertEquals(result, validated)
        assertEquals("opaque", output.getJSONObject("tls").getJSONObject("reality").getString("public_key"))
        assertTrue(output.has("future_parameter"))
    }

    @Test fun selectsUniquePreferredTagFromMultipleVlessNodes() {
        val input = JSONObject().put("outbounds", listOf(node("other"), node("R3-N1"), node("third")))
        assertEquals("R3-N1", JSONObject(ConfigurationParser.parseVless(input.toString())!!).getString("tag"))
    }

    @Test fun rejectsAmbiguousAndDuplicatePreferredTags() {
        rejectsVless(JSONObject().put("outbounds", listOf(node("one"), node("two"))).toString())
        rejectsVless(JSONObject().put("outbounds", listOf(node("R3-N1"), node("R3-N1"))).toString())
    }

    @Test fun emptyVlessSetDisablesModeRatherThanAcceptingAnotherProtocol() {
        assertNull(ConfigurationParser.parseVless("{\"outbounds\":[{\"type\":\"direct\"}]}"))
    }

    @Test fun rejectsBooleanFractionalStringAndOutOfRangePorts() {
        listOf(true, "443", 443.5, 0, 65536, -1).forEach { rejectsVless(node().put("server_port", it).toString()) }
        assertNotNull(ConfigurationParser.parseVless(node().put("server_port", 65535).toString()))
    }

    @Test fun rejectsMalformedUuidAndAnyDetourPresence() {
        rejectsVless(node().put("uuid", "1-1-1-1-1").toString())
        rejectsVless(node().put("uuid", "not-a-uuid").toString())
        rejectsVless(node().put("detour", JSONObject.NULL).toString())
        rejectsVless(node().put("detour", "another-proxy").toString())
    }

    @Test fun coreValidationFailureIsSanitized() {
        try {
            ConfigurationParser.parseVless(node().toString()) { throw IllegalArgumentException("secret-token-password") }
            fail("Expected core validation to reject")
        } catch (error: ProfileException) {
            assertFalse(error.message!!.contains("secret-token-password"))
            assertNull(error.cause)
        }
    }

    @Test fun rejectsImportedFilesystemReferencesButPreservesTransportNetworkPath() {
        listOf("certificate_path", "client_certificate_path", "client_key_path", "config_path", "certificatePath").forEach { key ->
            rejectsVless(node().put("tls", JSONObject().put("nested", JSONObject().put(key, "/private/secret"))).toString())
        }
        val input = node().put("transport", JSONObject().put("type", "ws").put("path", "/vpn?token=opaque"))
        assertEquals("/vpn?token=opaque", JSONObject(ConfigurationParser.parseVless(input.toString())!!).getJSONObject("transport").getString("path"))
    }

    @Test fun rejectsOversizedAndNonObjectVless() {
        rejectsVless(node().put("padding", "x".repeat(ConfigurationParser.MAX_CONFIG_BYTES)).toString())
        rejectsVless("[]")
    }

    @Test fun importsWdttAndUsesInstallationId() {
        val result = JSONObject(ConfigurationParser.parseTurn("wdtt://relay.example.test:443:unused:unused:test-password:callHash,other#name", "install-123"))
        val proxy = result.getJSONObject("proxy")
        assertEquals("relay.example.test:443", proxy.getString("peer_addr"))
        assertEquals("https://vk.ru/call/join/callHash", proxy.getString("vk_link"))
        assertEquals("test-password", proxy.getString("wrap_a_password"))
        assertEquals("install-123", proxy.getString("device_id"))
        assertTrue(proxy.getBoolean("use_wrap_a"))
        assertEquals(30, proxy.getInt("num_conns"))
        assertFalse(result.has("wireguard"))
    }

    @Test fun wdttAcceptsFirstFullVkJoinLinkButRejectsMalformedEndpointOrHash() {
        val result = JSONObject(ConfigurationParser.parseTurn("wdtt://relay.example.test:443:x:x:p:https://vk.com/call/join/hash", "id"))
        assertEquals("https://vk.ru/call/join/hash", result.getJSONObject("proxy").getString("vk_link"))
        listOf(
            "wdtt://relay.example.test:0:x:x:p:hash",
            "wdtt://relay.example.test:443:x:x::hash",
            "wdtt://relay.example.test:443:x:x:p:hash/extra",
            "wdtt://user@relay.example.test:443:x:x:p:hash",
            "wdtt://relay.example.test:443:x:x:p:hash\ncontrol",
        ).forEach { rejectsTurn(it) }
    }

    @Test fun importEnvelopeAcceptsUrlSafeAndStandardBase64WithoutCopyingDeviceId() {
        val settings = wrapSettings().put("device_id", "imported-secret-id")
        val root = JSONObject().put("version", 1).put("type", "connection").put("settings", settings)
        listOf(Base64.getEncoder(), Base64.getUrlEncoder().withoutPadding()).forEach { encoder ->
            val link = "vkturnproxy://import?data=" + encoder.encodeToString(root.toString().toByteArray())
            val proxy = JSONObject(ConfigurationParser.parseTurn(link, "android-install")).getJSONObject("proxy")
            assertEquals("android-install", proxy.getString("device_id"))
            assertEquals(2, proxy.getInt("num_conns"))
        }
    }

    @Test fun rejectsLegacySrtpBeforeNativeBootstrap() {
        val key = Base64.getEncoder().encodeToString(ByteArray(32) { (it + 1).toByte() })
        val settings = JSONObject().put("useSrtp", true)
            .put("vkLink", "https://vk.me/join/hash").put("peerAddress", "relay.example.test:443")
            .put("privateKey", key).put("peerPublicKey", key).put("presharedKey", key)
            .put("tunnelAddress", "10.20.30.40/32").put("turnServerOverride", "turn.example.test:3478")
        try {
            ConfigurationParser.parseTurn(envelope(settings), "id")
            fail("Android only supports the WRAP-A profile")
        } catch (error: ProfileException) {
            assertTrue(error.message!!.contains("WRAP-A"))
            assertFalse(error.message!!.contains(key))
        }
    }

    @Test fun rejectsUnsupportedTurnModesMalformedFieldsAndDuplicateData() {
        listOf("useWrap", "useWrapS", "useCsqtt", "useCookieAuth").forEach {
            rejectsTurn(envelope(wrapSettings().put(it, true)))
        }
        rejectsTurn(envelope(wrapSettings().put("numConnections", true)))
        rejectsTurn(envelope(wrapSettings().put("numConnections", 51)))
        rejectsTurn(envelope(wrapSettings().put("useUDP", "true")))
        rejectsTurn(envelope(wrapSettings().put("vkLink", "https://attacker.example.test/call/join/hash")))
        rejectsTurn(envelope(wrapSettings().put("wrapAPassword", "pass\nword")))
        rejectsTurn(envelope(wrapSettings().put("useWrapA", false)))
        rejectsTurn("vkturnproxy://import?data=YWJj&data=YWJj")
        rejectsTurn("vkturnproxy://import?data=%%%")
    }

    @Test fun validSecondModeAndSelectionSurviveMissingFirstMode() {
        val old = Snapshot(vless = "old", turn = "valid", selectedMode = SelectedMode.VLESS)
        val updated = old.copy(vless = null).withAvailableMode()
        assertEquals("valid", updated.turn)
        assertEquals(SelectedMode.TURN, updated.selectedMode)
        val empty = updated.copy(turn = null).withAvailableMode()
        assertFalse(empty.hasMode(SelectedMode.VLESS))
        assertFalse(empty.hasMode(SelectedMode.TURN))
    }

    @Test fun snapshotStringNeverDisclosesSecrets() {
        val text = Snapshot(source = "secret-url", vless = "secret-uuid", turn = "secret-password").toString()
        assertFalse(text.contains("secret"))
    }

    private fun wrapSettings(): JSONObject = JSONObject().put("useWrapA", true)
        .put("vkLink", "https://vk.ru/call/join/hash").put("peerAddress", "relay.example.test:443")
        .put("wrapAPassword", "test-password").put("numConnections", 2)

    private fun envelope(settings: JSONObject): String {
        val root = JSONObject().put("version", 1).put("type", "connection").put("settings", settings)
        return "vkturnproxy://import?data=" + Base64.getUrlEncoder().withoutPadding().encodeToString(root.toString().toByteArray())
    }

    private fun rejectsVless(text: String) {
        try { ConfigurationParser.parseVless(text); fail("Expected VLESS rejection") } catch (_: ProfileException) { }
    }

    private fun rejectsTurn(text: String) {
        try { ConfigurationParser.parseTurn(text, "id"); fail("Expected TURN rejection") } catch (_: ProfileException) { }
    }
}
