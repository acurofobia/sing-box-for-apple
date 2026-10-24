import Foundation

struct PrototypeUIDocument: Codable, Sendable {
    let schemaVersion: Int
    let blocks: [PrototypeUIBlock]
    let pages: [PrototypeUIPage]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 * 1024, String(data: data, encoding: .utf8) != nil else {
            throw PrototypeUIError.invalidDocument
        }
        var parser = PrototypeJSONParser(data: data)
        let root = try parser.parse()
        try PrototypeUIValidator.validate(root)
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw PrototypeUIError.invalidDocument
        }
    }

    static func date(from source: String) -> Date? {
        PrototypeUIValidator.date(source)
    }

    func block(_ id: String) -> PrototypeUIBlock? {
        blocks.first { $0.id == id && $0.isVisible }
    }
}

struct PrototypeUIBlock: Codable, Identifiable, Sendable {
    enum Kind: String, Codable { case card, valueRow, actionSheet, selectionList, menu, progress }
    let id: String
    let type: Kind
    let visible: Bool?
    let title: String?
    let subtitle: String?
    let text: String?
    let buttons: [PrototypeUIButton]?
    let items: [PrototypeUIItem]?
    let value: Int64?
    let maximum: Int64?
    let unit: String?
    let period: String?
    let resetAt: String?
    var isVisible: Bool {
        visible ?? true
    }
}

struct PrototypeUIButton: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let visible: Bool?
    let action: PrototypeUIAction
    var isVisible: Bool {
        visible ?? true
    }
}

struct PrototypeUIItem: Codable, Identifiable, Sendable {
    enum State: String, Codable { case available, restricted, unavailable }
    let id: String
    let title: String
    let visible: Bool?
    let text: String?
    let state: State?
    let stateText: String?
    let detailsPageId: String?
    let buttons: [PrototypeUIButton]?
    let action: PrototypeUIAction?
    var isVisible: Bool {
        visible ?? true
    }
}

struct PrototypeUIPage: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let text: String
}

struct PrototypeUIAction: Codable, Sendable {
    enum Kind: String, Codable { case openExternalUrl, openScreen, openBlock }
    let type: Kind
    let url: String?
    let targetId: String?
}

enum PrototypeUIError: LocalizedError {
    case invalidDocument
    var errorDescription: String? {
        String(localized: "Сервер вернул некорректное оформление подписки.")
    }
}

/// Preserve number tokens and object keys: JSONDecoder alone loses duplicate keys
/// and accepts some floating-point representations as integers.
private indirect enum PrototypeJSON {
    case object([String: PrototypeJSON]), array([PrototypeJSON]), string(String), number(String), bool(Bool), null
}

private struct PrototypeJSONParser {
    let bytes: [UInt8]
    var index = 0
    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> PrototypeJSON {
        let result = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw PrototypeUIError.invalidDocument }
        return result
    }

    mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func string() throws -> String {
        whitespace()
        let start = index
        guard take(34) else { throw PrototypeUIError.invalidDocument }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 92 {
                guard index < bytes.count else { throw PrototypeUIError.invalidDocument }
                index += 1
            } else if byte == 34 {
                do {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start ..< index]))
                } catch {
                    throw PrototypeUIError.invalidDocument
                }
            }
        }
        throw PrototypeUIError.invalidDocument
    }

    mutating func value(depth: Int) throws -> PrototypeJSON {
        whitespace()
        guard depth < 128, index < bytes.count else { throw PrototypeUIError.invalidDocument }
        if bytes[index] == 34 {
            return try .string(string())
        }
        if take(123) {
            var fields: [String: PrototypeJSON] = [:]
            if take(125) {
                return .object(fields)
            }
            repeat {
                let key = try string()
                guard fields[key] == nil, take(58) else { throw PrototypeUIError.invalidDocument }
                fields[key] = try value(depth: depth + 1)
                if take(125) {
                    return .object(fields)
                }
                guard take(44) else { throw PrototypeUIError.invalidDocument }
            } while true
        }
        if take(91) {
            var values: [PrototypeJSON] = []
            if take(93) {
                return .array(values)
            }
            repeat {
                try values.append(value(depth: depth + 1))
                if take(93) {
                    return .array(values)
                }
                guard take(44) else { throw PrototypeUIError.invalidDocument }
            } while true
        }
        for (literal, result) in [("true", PrototypeJSON.bool(true)), ("false", .bool(false)), ("null", .null)] {
            let token = Array(literal.utf8)
            if bytes[index...].starts(with: token) {
                index += token.count
                return result
            }
        }
        let start = index
        while index < bytes.count, [UInt8(45), 43, 46, 69, 101].contains(bytes[index]) ||
            (index < bytes.count && (48 ... 57).contains(bytes[index]))
        {
            index += 1
        }
        guard let token = String(bytes: bytes[start ..< index], encoding: .utf8),
              token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
        else {
            throw PrototypeUIError.invalidDocument
        }
        return .number(token)
    }
}

private enum PrototypeUIValidator {
    static func object(_ node: PrototypeJSON, required: Set<String>, optional: Set<String> = []) throws -> [String: PrototypeJSON] {
        guard case let .object(fields) = node, required.isSubset(of: Set(fields.keys)),
              Set(fields.keys).isSubset(of: required.union(optional)) else { throw PrototypeUIError.invalidDocument }
        return fields
    }

    static func array(_ node: PrototypeJSON?) throws -> [PrototypeJSON] {
        guard case let .array(values) = node else { throw PrototypeUIError.invalidDocument }
        return values
    }

    @discardableResult static func text(_ node: PrototypeJSON?, minimum: Int = 1, maximum: Int = 4096) throws -> String {
        guard case let .string(value) = node, (minimum ... maximum).contains(value.unicodeScalars.count) else {
            throw PrototypeUIError.invalidDocument
        }
        return value
    }

    static func identifier(_ node: PrototypeJSON?) throws -> String {
        let value = try text(node, maximum: 64)
        guard value.range(of: #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) == value.startIndex ..< value.endIndex else {
            throw PrototypeUIError.invalidDocument
        }
        return value
    }

    static func integer(_ node: PrototypeJSON?) throws -> Int64 {
        guard case let .number(token) = node, token.allSatisfy(\.isNumber),
              let value = Int64(token), (0 ... 9_007_199_254_740_991).contains(value)
        else {
            throw PrototypeUIError.invalidDocument
        }
        return value
    }

    static func common(_ fields: [String: PrototypeJSON]) throws {
        if let visible = fields["visible"], case .bool = visible {} else if fields["visible"] != nil {
            throw PrototypeUIError.invalidDocument
        }
        for name in ["title", "subtitle"] where fields[name] != nil {
            try text(fields[name])
        }
        if let value = fields["text"] {
            try text(value, minimum: 0)
        }
    }

    static func externalURL(_ source: String) -> URL? {
        guard source.unicodeScalars.count <= 2048,
              !source.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || $0 == "\\" }),
              let parts = URLComponents(string: source), parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.port.map({ (1 ... 65535).contains($0) }) ?? true else { return nil }
        return parts.url
    }

    static func date(_ source: String) -> Date? {
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:[.,]([0-9]+))?)?(Z|[+-][0-9]{2}:?[0-9]{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.range.length == source.utf16.count else { return nil }
        func part(_ index: Int) -> String? {
            Range(match.range(at: index), in: source).map { String(source[$0]) }
        }
        let second = part(6).flatMap(Int.init) ?? 0
        guard let year = part(1).flatMap(Int.init), (1 ... 9999).contains(year),
              let month = part(2).flatMap(Int.init), let day = part(3).flatMap(Int.init),
              let hour = part(4).flatMap(Int.init), (0 ... 23).contains(hour),
              let minute = part(5).flatMap(Int.init), (0 ... 59).contains(minute),
              (0 ... 59).contains(second), let offset = part(8) else { return nil }
        var offsetSeconds = 0
        if offset != "Z" {
            let digits = offset.dropFirst().filter { $0 != ":" }
            guard digits.count == 4, let hours = Int(digits.prefix(2)), hours < 24,
                  let minutes = Int(digits.suffix(2)), minutes < 60 else { return nil }
            offsetSeconds = (hours * 3600 + minutes * 60) * (offset.first == "-" ? -1 : 1)
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        let fraction = part(7).flatMap { Double("0." + $0) } ?? 0
        return date.addingTimeInterval(fraction - Double(offsetSeconds))
    }

    static func validate(_ root: PrototypeJSON) throws {
        let document = try object(root, required: ["schemaVersion", "blocks", "pages"])
        guard try integer(document["schemaVersion"]) == 1 else { throw PrototypeUIError.invalidDocument }
        var identifiers: Set<String> = []
        var blockTypes: [String: String] = [:]
        var pageIDs: Set<String> = []
        var blockReferences: [String] = []
        var pageReferences: [String] = []
        func register(_ node: PrototypeJSON?) throws -> String {
            let id = try identifier(node)
            guard identifiers.insert(id).inserted else { throw PrototypeUIError.invalidDocument }
            return id
        }
        func action(_ node: PrototypeJSON?) throws {
            guard let node else { throw PrototypeUIError.invalidDocument }
            let fields = try object(node, required: ["type"], optional: ["url", "targetId"])
            let kind = try text(fields["type"])
            if kind == "openExternalUrl" {
                _ = try object(node, required: ["type", "url"])
                guard try externalURL(text(fields["url"], maximum: 2048)) != nil else { throw PrototypeUIError.invalidDocument }
            } else {
                guard ["openScreen", "openBlock"].contains(kind) else { throw PrototypeUIError.invalidDocument }
                _ = try object(node, required: ["type", "targetId"])
                let target = try identifier(fields["targetId"])
                if kind == "openBlock" {
                    blockReferences.append(target)
                }
            }
        }
        func button(_ node: PrototypeJSON) throws {
            let fields = try object(node, required: ["id", "title", "action"], optional: ["visible"])
            _ = try register(fields["id"])
            try common(fields)
            try action(fields["action"])
        }
        let slots = ["block01": "card", "block02": "valueRow", "block03": "actionSheet",
                     "block04": "selectionList", "block05": "menu", "block06": "progress"]
        for node in try array(document["blocks"]) {
            guard case let .object(raw) = node else { throw PrototypeUIError.invalidDocument }
            let kind = try text(raw["type"])
            var required: Set = ["id", "type"]
            var optional: Set = ["visible", "title", "subtitle", "text"]
            switch kind {
            case "card", "valueRow", "actionSheet": required.formUnion(["title", "buttons"])
            case "selectionList", "menu": required.insert("items")
            case "progress":
                required.formUnion(["value", "maximum", "unit"])
                optional.formUnion(["period", "resetAt"])
            default: throw PrototypeUIError.invalidDocument
            }
            let fields = try object(node, required: required, optional: optional)
            let id = try register(fields["id"])
            guard slots[id] == nil || slots[id] == kind else { throw PrototypeUIError.invalidDocument }
            blockTypes[id] = kind
            try common(fields)
            switch kind {
            case "card", "valueRow", "actionSheet":
                for item in try array(fields["buttons"]) {
                    try button(item)
                }
            case "menu":
                for item in try array(fields["items"]) {
                    try button(item)
                }
            case "selectionList":
                for item in try array(fields["items"]) {
                    let choice = try object(item, required: ["id", "title", "text", "state", "buttons"],
                                            optional: ["visible", "stateText", "detailsPageId"])
                    _ = try register(choice["id"])
                    try common(choice)
                    guard try ["available", "restricted", "unavailable"].contains(text(choice["state"])) else { throw PrototypeUIError.invalidDocument }
                    if let value = choice["stateText"], case .null = value {} else if let value = choice["stateText"] {
                        try text(value)
                    }
                    if let value = choice["detailsPageId"], case .null = value {} else if let value = choice["detailsPageId"] {
                        try pageReferences.append(identifier(value))
                    }
                    for value in try array(choice["buttons"]) {
                        try button(value)
                    }
                }
            default:
                let value = try integer(fields["value"])
                let maximum = try integer(fields["maximum"])
                guard maximum > 0, value <= maximum, try ["bytes", "count", "percent"].contains(text(fields["unit"])) else { throw PrototypeUIError.invalidDocument }
                if let period = fields["period"], try !["day", "week", "month", "total"].contains(text(period)) {
                    throw PrototypeUIError.invalidDocument
                }
                if let date = fields["resetAt"], case .null = date {} else if let date = fields["resetAt"] {
                    let source = try text(date)
                    guard Self.date(source) != nil else { throw PrototypeUIError.invalidDocument }
                }
            }
        }
        for node in try array(document["pages"]) {
            let page = try object(node, required: ["id", "title", "text"])
            try pageIDs.insert(register(page["id"]))
            try text(page["title"])
            try text(page["text"], minimum: 0, maximum: 32768)
        }
        guard blockReferences.allSatisfy({ blockTypes[$0] == "actionSheet" }), pageReferences.allSatisfy({ pageIDs.contains($0) }) else {
            throw PrototypeUIError.invalidDocument
        }
    }
}

extension PrototypeUIAction {
    var externalURL: URL? {
        url.flatMap(PrototypeUIValidator.externalURL)
    }
}
