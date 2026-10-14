import Foundation
import Libbox

public struct PriorityFailoverConfiguration: Codable, Equatable, Sendable {
    public var selector: String
    public var primary: String
    public var backups: [String]
    public var intervalMilliseconds: Int32
    public var timeoutMilliseconds: Int32
    public var failureThreshold: Int32
    public var recoveryThreshold: Int32

    public init(selector: String = "", primary: String = "", backups: [String] = [],
                intervalMilliseconds: Int32 = 10000, timeoutMilliseconds: Int32 = 5000,
                failureThreshold: Int32 = 2, recoveryThreshold: Int32 = 3) {
        self.selector = selector
        self.primary = primary
        self.backups = backups
        self.intervalMilliseconds = intervalMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
        self.failureThreshold = failureThreshold
        self.recoveryThreshold = recoveryThreshold
    }

    public func json() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public func validate(configContent: String) throws {
        var error: NSError?
        LibboxValidatePriorityFailover(configContent, try json(), &error)
        if let error { throw error }
    }
}

public struct PriorityFailoverMetadata: Decodable, Sendable {
    public struct Selector: Decodable, Identifiable, Sendable {
        public let tag: String
        public let candidates: [String]
        public let `default`: String
        public var id: String { tag }
    }

    public struct Outbound: Decodable, Sendable {
        public let tag: String
        public let type: String
    }

    public let selectors: [Selector]
    public let outbounds: [Outbound]

    public static func read(configContent: String) throws -> Self {
        var error: NSError?
        let json = LibboxPriorityFailoverMetadata(configContent, &error)
        if let error { throw error }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}

public struct PriorityFailoverStatus: Codable, Sendable {
    public let mode: String
    public let selector: String?
    public let selected: String?
    public let primaryHealth: String?
    public let allDown: Bool
}

struct PriorityFailoverRequest: Codable {
    enum Action: String, Codable { case status, resume, captureMemory }
    let kind: String
    let action: Action
    let phase: String?
    let seconds: Int?

    init(action: Action, phase: String? = nil, seconds: Int? = nil) {
        kind = "priorityFailover"
        self.action = action
        self.phase = phase
        self.seconds = seconds
    }
}

struct PriorityFailoverResponse: Codable {
    let status: PriorityFailoverStatus?
    let error: String?
}
