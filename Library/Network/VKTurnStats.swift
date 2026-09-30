import Foundation

public struct VKTurnStats: Decodable {
    public let txBytes: Int64
    public let rxBytes: Int64
    public let activeConns: Int
    public let totalConns: Int
    public let turnRTTms: Double
    public let dtlsHandshakeMs: Double
    public let reconnects: Int64
    public let credPoolFilled: Int
    public let credPoolWithCreds: Int
    public let credPoolSize: Int
    public let credPoolDistinctRelays: Int
    public let credPoolQuotaRefusals: Int64
    public let credPoolMintPausedSec: Int
    public let tunnelUptimeSec: Int64
    public let authError: String?

    enum CodingKeys: String, CodingKey {
        case txBytes = "tx_bytes"
        case rxBytes = "rx_bytes"
        case activeConns = "active_conns"
        case totalConns = "total_conns"
        case turnRTTms = "turn_rtt_ms"
        case dtlsHandshakeMs = "dtls_handshake_ms"
        case reconnects
        case credPoolFilled = "cred_pool_filled"
        case credPoolWithCreds = "cred_pool_with_creds"
        case credPoolSize = "cred_pool_size"
        case credPoolDistinctRelays = "cred_pool_distinct_relays"
        case credPoolQuotaRefusals = "cred_pool_quota_refusals"
        case credPoolMintPausedSec = "cred_pool_mint_paused_sec"
        case tunnelUptimeSec = "tunnel_uptime_sec"
        case authError = "auth_error"
    }
}
