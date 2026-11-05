import Foundation

/// ApplicationOpeningFailure carries observed state across the session boundary, without UI instructions.
public struct ApplicationOpeningFailure: Error, LocalizedError {
    public enum State: String, Sendable {
        case unverifiedTarget = "opening_target_unverified"
        case previousRetained = "opening_previous_retained"
        case noActiveSession = "opening_no_active_session"
    }

    /// Reason retains structural lookup and selection causes with their observed opening stage.
    public enum Reason: Sendable {
        case applicationNotFound(String)
        case applicationAmbiguous(String, matches: Int)
        case windowTitleMismatch(WindowSelection)

        public var code: String {
            switch self {
            case .applicationNotFound: "opening_application_not_found"
            case .applicationAmbiguous: "opening_application_ambiguous"
            case .windowTitleMismatch: "opening_window_title_mismatch"
            }
        }
    }

    /// WindowSelection records the exact comparison and cleanup facts at the requested-selection guard.
    public struct WindowSelection: Sendable {
        public let application: String
        public let requested: String
        public let available: [String]
        public let matches: Int
        /// False when selecting within the held app without requesting an opening.
        public let openingAttempted: Bool
        public let wasLaunched: Bool
        /// Acceptance of a quit request, never confirmation that the process exited.
        public let quitRequestAccepted: Bool

        public init(application: String, requested: String, available: [String], matches: Int,
                    wasLaunched: Bool, quitRequestAccepted: Bool, openingAttempted: Bool = true) {
            self.application = application
            self.requested = requested
            self.available = available
            self.matches = matches
            self.openingAttempted = openingAttempted
            self.wasLaunched = wasLaunched
            self.quitRequestAccepted = quitRequestAccepted
        }
    }

    public struct Launch: Sendable {
        public let application: String
        public let seconds: Int64
        public let wasLaunched: Bool
        /// Acceptance of a quit request, never confirmation that the process exited.
        public let quitRequestAccepted: Bool

        public init(application: String, seconds: Int64, wasLaunched: Bool, quitRequestAccepted: Bool) {
            self.application = application
            self.seconds = seconds
            self.wasLaunched = wasLaunched
            self.quitRequestAccepted = quitRequestAccepted
        }
    }

    public let state: State
    public let underlying: (any Error)?
    public let launch: Launch?
    public let cleanupWarning: String?
    public let reason: Reason?

    public init(state: State, underlying: (any Error)? = nil, launch: Launch? = nil,
                cleanupWarning: String? = nil, reason: Reason? = nil) {
        self.state = state
        self.underlying = underlying
        self.launch = launch
        self.cleanupWarning = cleanupWarning
        self.reason = reason
    }

    public var causeCode: String { reason?.code ?? state.rawValue }

    /// Only failed lookup attests no earlier opening or observation effects in this request.
    public var isBeforeApplicationLaunch: Bool {
        switch reason {
        case .applicationNotFound?, .applicationAmbiguous?: true
        case .windowTitleMismatch?: false
        case nil: false
        }
    }

    /// Returns the same cause with the session state observed by its owner after cleanup.
    public func reporting(state: State, cleanupWarning: String? = nil) -> Self {
        let warnings = [self.cleanupWarning, cleanupWarning].compactMap { $0 }
        let unique = warnings.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return Self(state: state, underlying: underlying, launch: launch,
                    cleanupWarning: unique.isEmpty ? nil : unique.joined(separator: " "), reason: reason)
    }

    /// A machine diagnosis for library callers. Tool and CLI consumers render the shared ModelText catalogue.
    public var errorDescription: String? {
        if reason != nil { return causeCode + ": " + state.rawValue }
        return state.rawValue + (underlying.map { ": " + $0.localizedDescription } ?? "")
    }
}
