import ChatCore
import FileConversations
import Foundation

/// ChatTranscript serializes live provider and tool events into one conversation on the main actor.
final class ChatTranscript {
    var conversation: Conversation
    let store: ConversationStore
    /// The last token counts the provider reported, for a script's evidence; nil when it reported none.
    private(set) var lastUsage: ProviderUsage?

    init(conversation: Conversation, store: ConversationStore) {
        self.conversation = conversation
        self.store = store
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
        case .usage(let usage): lastUsage = usage
        case .compacted, .web, .completed: break
        }
    }

    func save() throws { try store.save(conversation) }
}
