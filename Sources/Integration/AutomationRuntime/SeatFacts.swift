/// SeatFacts separates Braus's own structured seat facts from the original legacy rendering.
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
    /// The original seat line, preserved byte for byte for v1.
    public let legacyText: String

    public init(
        session: Bool = false,
        application: Application? = nil,
        missingPermissions: [String] = [],
        legacyText: String
    ) {
        self.session = session
        self.application = application
        self.missingPermissions = missingPermissions
        self.legacyText = legacyText
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

/// SeatLineArm selects the original text by default or the bounded facts block.
nonisolated public enum SeatLineArm: String, Sendable {
    case v1, v2
}
