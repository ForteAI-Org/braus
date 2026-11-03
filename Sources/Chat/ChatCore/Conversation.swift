import Foundation

/// Conversation stores a provider reference and a local transcript, never credentials or a live Seat.
public struct Conversation: Codable, Sendable, Identifiable {
    public let id: UUID
    public var provider: ChatProvider
    /// The API or local provider for Braus's loop; nil preserves the command line route.
    public var modelProvider: String?
    public var model: String?
    public var providerSessionID: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var entries: [Entry]

    public init(id: UUID = UUID(), provider: ChatProvider, model: String?, now: Date = Date(), modelProvider: String? = nil) {
        self.id = id
        self.provider = provider
        self.modelProvider = modelProvider
        self.model = model
        self.createdAt = now
        self.updatedAt = now
        self.entries = []
    }

    public var title: String {
        String((entries.first(where: { $0.kind == .user })?.text ?? "New conversation").prefix(80))
    }

    public mutating func append(_ kind: Entry.Kind, _ text: String, now: Date = Date()) {
        entries.append(Entry(kind: kind, text: text, date: now))
        updatedAt = now
    }

    public struct Entry: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case user, assistant, tool, error, interrupted
        }
        public let kind: Kind
        public let text: String
        public let date: Date
    }
}
