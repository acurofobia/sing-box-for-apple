package io.whitelink.android.data

/** A strict small decoder, shared by API 24 Android and JVM parser tests. */
internal object BinaryEncoding {
    fun decodeBase64(value: String): ByteArray {
        val text = value.replace('-', '+').replace('_', '/')
        val raw = text.trimEnd('=')
        val padding = text.length - raw.length
        require(raw.isNotEmpty() && raw.length % 4 != 1 && padding <= 2)
        require(padding == 0 || (text.length % 4 == 0 && padding == (4 - raw.length % 4) % 4))
        val output = ByteArray(raw.length * 6 / 8)
        var accumulator = 0
        var bits = 0
        var index = 0
        raw.forEach { char ->
            val digit = when (char) {
                in 'A'..'Z' -> char - 'A'
                in 'a'..'z' -> char - 'a' + 26
                in '0'..'9' -> char - '0' + 52
                '+' -> 62
                '/' -> 63
                else -> throw IllegalArgumentException("Invalid base64")
            }
            accumulator = (accumulator shl 6) or digit
            bits += 6
            if (bits >= 8) {
                bits -= 8
                output[index++] = (accumulator shr bits).toByte()
                accumulator = accumulator and ((1 shl bits) - 1)
            }
        }
        require(accumulator == 0)
        return output
    }
}
