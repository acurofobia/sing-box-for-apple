package io.whitelink.android.data

import org.junit.Assert.*
import org.junit.Test

class StrictJsonTest {
    @Test fun acceptsEscapedStringsNumbersArraysAndWhitespace() {
        val root = StrictJson.objectValue(" \n{\"text\":\"escaped \\\" \\u0041\",\"values\":[-1,1.2e+3,true,null]}\r\n", 1024)
        assertEquals("escaped \" A", root.getString("text"))
        assertEquals(4, root.getJSONArray("values").length())
    }

    @Test fun rejectsAndroidLenientSyntaxAndTrailingData() {
        listOf("{'a':1}", "{a:1}", "{\"a\":1,}", "{\"a\":[1,]}", "{\"a\":01}",
            "{\"a\":+1}", "{\"a\":NaN}", "{\"a\":1.}", "{\"a\":.1}", "{\"a\":1e}",
            "{/*comment*/\"a\":1}", "{} {}", "[]", "null", "{\"a\":\"\n\"}")
            .forEach { rejects(it) }
    }

    @Test fun rejectsDuplicateKeysIncludingEscapedEquivalentKeys() {
        rejects("{\"a\":1,\"a\":2}")
        rejects("{\"a\":1,\"\\u0061\":2}")
        rejects("{\"nested\":{\"key\":1,\"key\":2}}")
    }

    @Test fun enforcesByteCountAndDepthLimits() {
        try { StrictJson.objectValue("{\"a\":\"я\"}", 9); fail("UTF-8 bytes exceed cap") } catch (_: ProfileException) { }
        rejects("{\"nested\":" + "[".repeat(66) + "0" + "]".repeat(66) + "}")
    }

    @Test fun strictBase64PreservesBytesAndRejectsNoncanonicalPadding() {
        assertArrayEquals(byteArrayOf(1, 2, 3), BinaryEncoding.decodeBase64("AQID"))
        assertArrayEquals(byteArrayOf(0xfb.toByte(), 0xff.toByte()), BinaryEncoding.decodeBase64("-_8"))
        listOf("A", "AQ=", "AQ===", "AB==", "A=ID", "%%%%").forEach { text ->
            try { BinaryEncoding.decodeBase64(text); fail("Expected base64 rejection") } catch (_: IllegalArgumentException) { }
        }
    }

    private fun rejects(text: String) {
        try { StrictJson.objectValue(text, 4096); fail("Expected strict JSON rejection") } catch (_: ProfileException) { }
    }
}
