import ChatCore
import FileConversations
import Foundation

/// ChatTranscript serializes live provider and tool events into one conversation on the main actor.
final class ChatTranscript {
    var conversation: Conversation
    let store: ConversationStore
    /// The last token counts the provider reported, for a script's evidence; nil when it reported none.
    private(set) var lastUsage: ProviderUsage?
    /// What the current request cost: the sum of its provider runs (an interpretation reminder is a second run, whose
    /// counts alone the evidence held until 14 October 2026), or, for a provider that counts the whole session (Codex),
    /// the difference from the session's total before the request. Nil when the provider reported nothing.
    private(set) var requestTokens: ProviderUsage.Tokens?
    private var totalBefore: ProviderUsage.Tokens?

    init(conversation: Conversation, store: ConversationStore) {
        self.conversation = conversation
        self.store = store
    }

    /// Starts counting a new request's cost.
    func beginRequest() {
        requestTokens = nil
        totalBefore = lastUsage?.isSessionTotal == true ? lastUsage?.tokens : nil
    }

    func append(_ kind: Conversation.Entry.Kind, _ text: String) throws {
        conversation.append(kind, text)
        try save()
    }

    func event(_ event: ProviderEvent) throws {
        switch event {
        case .session(let id):
            if conversation.providerSessionID != id {
                conversation.providerSessionID = id
                try save()
            }
        case .assistant(let text):
            print("\n\(conversation.provider.displayName) › \(text)\n")
            try append(.assistant, text)
        case .activity(let text): print(text)
        case .failure(let text): try append(.error, text)
        case .usage(let usage):
            if usage.isSessionTotal {
                requestTokens = Self.adding(usage.tokens, totalBefore.map(Self.negated) ?? ProviderUsage.Tokens())
            } else {
                requestTokens = Self.adding(requestTokens ?? ProviderUsage.Tokens(), usage.tokens)
            }
            lastUsage = usage
        case .compacted, .web, .completed: break
        }
    }

    func save() throws { try store.save(conversation) }

    private static func adding(_ a: ProviderUsage.Tokens, _ b: ProviderUsage.Tokens) -> ProviderUsage.Tokens {
        ProviderUsage.Tokens(input: a.input + b.input, cacheReads: a.cacheReads + b.cacheReads,
                             cacheWrites: a.cacheWrites + b.cacheWrites, output: a.output + b.output,
                             reasoning: a.reasoning + b.reasoning)
    }

    private static func negated(_ a: ProviderUsage.Tokens) -> ProviderUsage.Tokens {
        ProviderUsage.Tokens(input: -a.input, cacheReads: -a.cacheReads, cacheWrites: -a.cacheWrites, output: -a.output,
                             reasoning: -a.reasoning)
    }
}
