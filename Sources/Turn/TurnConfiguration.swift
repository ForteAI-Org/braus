import Foundation

/// TurnConfiguration defines private file locations and host capabilities across turns.
nonisolated public struct TurnConfiguration: Sendable {
    public let workingDirectory: URL
    public let bridgeExecutable: URL
    /// A dedicated private directory owned by runner cleanup; nil creates a temporary one.
    public let connectionFolder: URL?
    public let allowsSuspension: Bool
    public let appInstructions: Bool

    public init(workingDirectory: URL, bridgeExecutable: URL, connectionFolder: URL? = nil,
                allowsSuspension: Bool, appInstructions: Bool = true) {
        self.workingDirectory = workingDirectory
        self.bridgeExecutable = bridgeExecutable
        self.connectionFolder = connectionFolder
        self.allowsSuspension = allowsSuspension
        self.appInstructions = appInstructions
    }
}
