import Foundation

/// TurnConfiguration defines private file locations and host capabilities across turns.
nonisolated public struct TurnConfiguration: Sendable {
    public let workingDirectory: URL
    public let bridgeExecutable: URL
    /// A dedicated private directory owned by runner cleanup; nil creates a temporary one.
    public let connectionFolder: URL?
    public let allowsSuspension: Bool
    /// Closes the Seat after failure or stop; the CLI owns that ordering itself.
    public let closesSessionOnEnd: Bool

    public init(workingDirectory: URL, bridgeExecutable: URL, connectionFolder: URL? = nil,
                allowsSuspension: Bool, closesSessionOnEnd: Bool = true) {
        self.workingDirectory = workingDirectory
        self.bridgeExecutable = bridgeExecutable
        self.connectionFolder = connectionFolder
        self.allowsSuspension = allowsSuspension
        self.closesSessionOnEnd = closesSessionOnEnd
    }
}
