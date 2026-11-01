import ChatCore
import Foundation
import ModelTransports

/// TurnRequest contains the route, context and host choices for one turn.
nonisolated public struct TurnRequest: Sendable {
    public enum Route: Sendable {
        case commandLine(provider: ChatProvider, executable: URL, model: String?, effort: String?,
                         environment: [String: String], allowsWebSearch: Bool)
        case modelLoop(transport: any ModelTransport, contextWindow: Int?)
    }
    public let prompt: String
    public let route: Route
    public let sessionID: String?
    public let history: [TurnMessage]
    public let role: String?
    public let reviewingHumanIntervention: Bool
    public let budget: TurnBudget
    public let previousSessionTotal: (session: String, tokens: ProviderUsage.Tokens)?
    public let previousContextTokens: Int?

    public init(
        prompt: String,
        route: Route,
        sessionID: String? = nil,
        history: [TurnMessage] = [],
        role: String? = nil,
        reviewingHumanIntervention: Bool = false,
        budget: TurnBudget = .off,
        previousSessionTotal: (session: String, tokens: ProviderUsage.Tokens)? = nil,
        previousContextTokens: Int? = nil
    ) {
        self.prompt = prompt
        self.route = route
        self.sessionID = sessionID
        self.history = history
        self.role = role
        self.reviewingHumanIntervention = reviewingHumanIntervention
        self.budget = budget
        self.previousSessionTotal = previousSessionTotal
        self.previousContextTokens = previousContextTokens
    }
}
