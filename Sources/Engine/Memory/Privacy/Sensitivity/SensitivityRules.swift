import Foundation

/// SensitivityRules contains versioned local rules. Invalid bundled rules stop initialization.
public struct SensitivityRules: Sendable, Codable {
    public let version: Int
    public let decisiveLabels: [String]
    public let weakLabels: [String]
    public let strongPatterns: [String]
    public let luhn: Bool
    public let iban: Bool
    public let appPolicies: [String: Int]
    public let markup: Markup

    /// Markup contains the shared native and JavaScript web attribute vocabulary.
    public struct Markup: Sendable, Codable {
        public let secretAutocomplete: Set<String>
        public let secretNames: Set<String>
        public let nonTextTypes: Set<String>
    }

    public static let bundled: Self = {
        do {
            guard let url = Bundle.module.url(forResource: "core", withExtension: "json", subdirectory: "Rules") else {
                preconditionFailure("Missing sensitivity rules")
            }
            let rules = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            precondition(rules.version == 1, "Unsupported sensitivity rules version")
            return rules
        } catch { preconditionFailure("Invalid sensitivity rules: \(error)") }
    }()
}
