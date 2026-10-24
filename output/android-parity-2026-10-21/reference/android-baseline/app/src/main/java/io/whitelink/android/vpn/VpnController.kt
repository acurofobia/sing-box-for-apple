/* WhiteLink. VPN integration derived from SagerNet/sing-box-for-android.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package io.whitelink.android.vpn

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import io.whitelink.android.data.ProfileStore
import io.whitelink.android.data.SelectedMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.File

enum class VpnPhase {
    DISCONNECTED, PREPARING, BOOTSTRAPPING, CONNECTING, CONNECTED,
    WAITING_FOR_NETWORK, RECONNECTING, STOPPING, ERROR
}

data class VpnUiState(
    val phase: VpnPhase = VpnPhase.DISCONNECTED,
    val mode: SelectedMode = SelectedMode.VLESS,
    val error: String? = null,
    val txBytes: Long = 0, val rxBytes: Long = 0,
    val txSpeed: Long = 0, val rxSpeed: Long = 0,
    val rssBytes: Long = 0, val pssBytes: Long = 0,
    val allocations: Int = 0,
    val updatedAt: Long = 0,
    val rssUpdatedAt: Long = 0, val pssUpdatedAt: Long = 0,
) {
    val isIdle: Boolean get() = phase == VpnPhase.DISCONNECTED || phase == VpnPhase.ERROR
}

/** All state lives in the same process as the only VPN service. */
object VpnController {
    internal val mutableState = MutableStateFlow(VpnUiState())
    val state: StateFlow<VpnUiState> = mutableState.asStateFlow()
    internal val mutableLogs = MutableStateFlow<List<String>>(emptyList())
    val logs: StateFlow<List<String>> = mutableLogs.asStateFlow()
    @Volatile internal var service: WhiteLinkVpnService? = null

    val isIdle: Boolean get() = state.value.isIdle && service?.cleanupPending != true

    fun connect(context: Context) {
        if (!isIdle) return
        try {
            val mode = ProfileStore(context).selectedMode()
            mutableState.value = VpnUiState(phase = VpnPhase.PREPARING, mode = mode)
            ContextCompat.startForegroundService(context, Intent(context, WhiteLinkVpnService::class.java)
                .setAction(WhiteLinkVpnService.CONNECT))
        } catch (_: Exception) {
            mutableState.update { it.copy(phase = VpnPhase.ERROR, error = "Не удалось запустить VPN.") }
        }
    }

    fun disconnect(context: Context) {
        val active = service
        if (active != null) active.requestStop()
        else mutableState.update { it.copy(phase = VpnPhase.DISCONNECTED, error = null,
            txSpeed = 0, rxSpeed = 0, rssBytes = 0, pssBytes = 0, allocations = 0) }
    }

    fun switchMode(context: Context, mode: SelectedMode) {
        if (mode == state.value.mode && !state.value.isIdle) return
        if (service?.cleanupPending == true || state.value.phase == VpnPhase.STOPPING) return
        try {
            val store = ProfileStore(context)
            if (!store.load().hasMode(mode)) {
                mutableState.update { it.copy(error = "Импортируйте конфигурацию выбранного режима.") }
                return
            }
            val active = service
            if (active != null && !state.value.isIdle) {
                if (state.value.phase != VpnPhase.CONNECTED && state.value.phase != VpnPhase.WAITING_FOR_NETWORK) return
                active.requestMode(mode)
            } else {
                store.selectMode(mode)
                mutableState.update { it.copy(mode = mode, error = null) }
            }
        } catch (_: Exception) {
            mutableState.update { it.copy(error = "Не удалось сохранить выбранный режим.") }
        }
    }

    fun diagnosticsFile(context: Context): File? = Diagnostics.latest(context)
}
