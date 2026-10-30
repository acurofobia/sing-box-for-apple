import Foundation

enum PrototypeLegalDocument: String, CaseIterable, Identifiable {
    case privacy, licenses, sources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return String(localized: "Конфиденциальность")
        case .licenses: return String(localized: "Лицензии")
        case .sources: return String(localized: "Исходный код")
        }
    }

    private var resource: String {
        switch self {
        case .privacy: return "PrivacyPolicy"
        case .licenses: return "Licenses"
        case .sources: return "SourceCode"
        }
    }

    func text(in bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(forResource: resource, withExtension: "txt", subdirectory: "Legal")
            ?? bundle.url(forResource: resource, withExtension: "txt")
        else { throw CocoaError(.fileNoSuchFile) }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard self == .sources else { return text }
        return text.replacingOccurrences(of: "{{version}}", with: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            .replacingOccurrences(of: "{{build}}", with: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
    }

    struct LicenseSection: Identifiable {
        let id: Int
        let title: String
        let text: String
    }

    static func licenseSections(from text: String) -> [LicenseSection] {
        let parts = text.components(separatedBy: String(repeating: "=", count: 78) + "\n")
        let documents = parts.count > 1 ? Array(parts.dropFirst()) : parts
        return documents.enumerated().compactMap { index, content in
            let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title = value.split(separator: "\n").first else { return nil }
            return LicenseSection(id: index, title: String(title), text: value)
        }
    }
}
