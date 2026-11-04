/// SeatFacts carries Braus's structured seat facts.
/// Structured fields contain no session identifier, window title or document name.
nonisolated public struct SeatFacts: Sendable, Equatable {
    /// Application identifies the current or last application, never a window or document.
    public struct Application: Sendable, Equatable {
        public let name: String
        public let bundleID: String

        public init(
            name: String,
            bundleID: String
        ) {
            self.name = name
            self.bundleID = bundleID
        }
    }

    public let session: Bool
    public let application: Application?
    public let missingPermissions: [String]

    public init(
        session: Bool = false,
        application: Application? = nil,
        missingPermissions: [String] = []
    ) {
        self.session = session
        self.application = application
        self.missingPermissions = missingPermissions
    }
}

/// SeatTaskFacts carries the task state; unknown todo and memory counts remain absent.
nonisolated public struct SeatTaskFacts: Sendable, Equatable {
    public let isOpen: Bool
    public let rowsDone: Int?
    public let rowsTotal: Int?
    public let learnedForApp: Int?

    public init(
        isOpen: Bool = false,
        rowsDone: Int? = nil,
        rowsTotal: Int? = nil,
        learnedForApp: Int? = nil
    ) {
        self.isOpen = isOpen
        self.rowsDone = rowsDone
        self.rowsTotal = rowsTotal
        self.learnedForApp = learnedForApp
    }
}
