package io.whitelink.android.data

/** Exactly one mode is active at a time; DIRECT is an explicit diagnostic mode. */
enum class SelectedMode { VLESS, TURN, DIRECT }

data class Snapshot(
    val source: String? = null,
    val vless: String? = null,
    /** libbox bootstrap fields: {"proxy": {...}, "wireguard": {...}}. */
    val turn: String? = null,
    val updatedAt: Long = 0L,
    val selectedMode: SelectedMode = SelectedMode.VLESS,
) {
    fun hasMode(mode: SelectedMode): Boolean = when (mode) {
        SelectedMode.VLESS -> vless != null
        SelectedMode.TURN -> turn != null
        SelectedMode.DIRECT -> true
    }

    fun withAvailableMode(): Snapshot {
        if (hasMode(selectedMode)) return this
        return copy(selectedMode = when {
            vless != null -> SelectedMode.VLESS
            turn != null -> SelectedMode.TURN
            else -> SelectedMode.VLESS
        })
    }

    // Never allow a UI/debug interpolation to disclose subscription URLs or keys.
    override fun toString(): String =
        "Snapshot(vless=${vless != null}, turn=${turn != null}, updatedAt=$updatedAt, selectedMode=$selectedMode)"
}

data class ImportResult(val snapshot: Snapshot, val warnings: List<String> = emptyList())

class ProfileException(message: String) : Exception(message)

/** Storage contract also allows exercising network transactions without Android/JNI. */
interface ProfileStorage {
    val deviceId: String
    fun load(): Snapshot
    fun save(snapshot: Snapshot)
    fun clear()
    fun mutate(recoverCorruptSnapshot: Boolean = false, transform: (Snapshot) -> Snapshot): Snapshot
}
