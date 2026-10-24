package io.whitelink.android.data

import org.json.JSONObject

/** Android's JSONTokener accepts non-JSON syntax; enforce RFC 8259 before using it. */
internal object StrictJson {
    fun objectValue(text: String, maxBytes: Int): JSONObject {
        if (text.toByteArray(Charsets.UTF_8).size > maxBytes) invalid()
        try {
            Scanner(text).validate()
            if (text.trimStart().firstOrNull() != '{') invalid()
            return JSONObject(text)
        } catch (_: ProfileException) {
            invalid()
        } catch (_: Exception) {
            invalid()
        }
    }

    private fun invalid(): Nothing = throw ProfileException("Некорректный JSON конфигурации.")

    private class Scanner(private val text: String) {
        private var offset = 0

        fun validate() {
            value(0)
            whitespace()
            if (offset != text.length) invalid()
        }

        private fun whitespace() {
            while (offset < text.length && text[offset] in " \t\n\r") offset++
        }

        private fun take(char: Char): Boolean {
            whitespace()
            if (offset < text.length && text[offset] == char) {
                offset++
                return true
            }
            return false
        }

        private fun value(depth: Int) {
            if (depth > 64) invalid()
            whitespace()
            when (text.getOrNull(offset)) {
                '{' -> {
                    offset++
                    val keys = HashSet<String>()
                    if (!take('}')) {
                        do {
                            whitespace()
                            if (text.getOrNull(offset) != '"') invalid()
                            if (!keys.add(string())) invalid()
                            if (!take(':')) invalid()
                            value(depth + 1)
                        } while (take(','))
                        if (!take('}')) invalid()
                    }
                }
                '[' -> {
                    offset++
                    if (!take(']')) {
                        do { value(depth + 1) } while (take(','))
                        if (!take(']')) invalid()
                    }
                }
                '"' -> string()
                't' -> literal("true")
                'f' -> literal("false")
                'n' -> literal("null")
                '-', in '0'..'9' -> number()
                else -> invalid()
            }
        }

        private fun literal(word: String) {
            if (!text.startsWith(word, offset)) invalid()
            offset += word.length
        }

        private fun number() {
            if (text.getOrNull(offset) == '-') offset++
            if (text.getOrNull(offset) == '0') {
                offset++
            } else {
                if (text.getOrNull(offset) !in '1'..'9') invalid()
                while (text.getOrNull(offset) in '0'..'9') offset++
            }
            if (text.getOrNull(offset) == '.') {
                offset++
                if (text.getOrNull(offset) !in '0'..'9') invalid()
                while (text.getOrNull(offset) in '0'..'9') offset++
            }
            if (text.getOrNull(offset) == 'e' || text.getOrNull(offset) == 'E') {
                offset++
                if (text.getOrNull(offset) == '+' || text.getOrNull(offset) == '-') offset++
                if (text.getOrNull(offset) !in '0'..'9') invalid()
                while (text.getOrNull(offset) in '0'..'9') offset++
            }
        }

        private fun string(): String {
            if (text.getOrNull(offset++) != '"') invalid()
            val result = StringBuilder()
            while (offset < text.length) {
                val char = text[offset++]
                when {
                    char == '"' -> return result.toString()
                    char < ' ' -> invalid()
                    char == '\\' -> {
                        val escaped = text.getOrNull(offset++) ?: invalid()
                        result.append(when (escaped) {
                            '"', '\\', '/' -> escaped
                            'b' -> '\b'
                            'f' -> '\u000C'
                            'n' -> '\n'
                            'r' -> '\r'
                            't' -> '\t'
                            'u' -> {
                                if (offset + 4 > text.length) invalid()
                                val code = text.substring(offset, offset + 4)
                                if (code.any { it !in "0123456789abcdefABCDEF" }) invalid()
                                offset += 4
                                code.toInt(16).toChar()
                            }
                            else -> invalid()
                        })
                    }
                    else -> result.append(char)
                }
            }
            invalid()
        }
    }
}
