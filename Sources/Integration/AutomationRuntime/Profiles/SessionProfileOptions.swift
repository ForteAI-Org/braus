import Foundation

extension SessionProfile {
    /// Options supplies resources and policies without changing the tool list.
    public nonisolated struct Options: Sendable, Equatable, Codable {
        public var harnessWebSearch: Bool
        public var seatWarmSeconds: Int
        public var holdsFromPlanToEnd: Bool
        public var providerCredential: ProviderCredential
        public var effort: String?
        public var guides: [URL]
        public var forbiddenApps: [String]

        public init(harnessWebSearch: Bool = false, seatWarmSeconds: Int = 30,
                    holdsFromPlanToEnd: Bool = false, providerCredential: ProviderCredential = .none,
                    effort: String? = nil, guides: [URL] = [], forbiddenApps: [String] = []) {
            self.harnessWebSearch = harnessWebSearch
            self.seatWarmSeconds = seatWarmSeconds
            self.holdsFromPlanToEnd = holdsFromPlanToEnd
            self.providerCredential = providerCredential
            self.effort = effort
            self.guides = guides
            self.forbiddenApps = forbiddenApps
        }
    }

    /// ProviderCredential names a credential source without storing its secret.
    public nonisolated enum ProviderCredential: Sendable, Equatable, Codable {
        case none, keychainService(String), namedVariable(String)

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            guard values.allKeys.count == 1, let key = values.allKeys.first else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one credential source."))
            }
            switch key.stringValue {
            case "none":
                guard try values.decode(Bool.self, forKey: key) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Expected true.")
                }
                self = .none
            case "keychainService", "namedVariable":
                let name = try values.decode(String.self, forKey: key)
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Expected a source name.")
                }
                self = key.stringValue == "keychainService" ? .keychainService(name) : .namedVariable(name)
            default:
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Unknown credential source.")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .keychainService(let name), .namedVariable(let name):
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw EncodingError.invalidValue(name, .init(codingPath: encoder.codingPath,
                        debugDescription: "Expected a credential source name."))
                }
            case .none: break
            }
            var values = encoder.container(keyedBy: Key.self)
            switch self {
            case .none: try values.encode(true, forKey: Key(stringValue: "none"))
            case .keychainService(let name): try values.encode(name, forKey: Key(stringValue: "keychainService"))
            case .namedVariable(let name): try values.encode(name, forKey: Key(stringValue: "namedVariable"))
            }
        }

        public var source: String {
            switch self {
            case .none: "none"
            case .keychainService: "keychainService"
            case .namedVariable: "namedVariable"
            }
        }
    }
}
