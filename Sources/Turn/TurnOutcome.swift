import ChatCore
import Foundation

/// TurnOutcome reports the whole successful turn, including an interpretation reminder.
nonisolated public struct TurnOutcome: Sendable {
    public let usage: TurnTokenUsage?
    public let lastReported: ProviderUsage?
    public let session: String?
    public let rounds: Int
    public let toolCalls: Int
    public let duration: Duration
}
