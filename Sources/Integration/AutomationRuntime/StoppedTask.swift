import Memory

/// StopCause identifies the host's explicit task termination.
public nonisolated enum StopCause: Sendable, Equatable { case person, signal(Int32), conversationEnded }

/// StoppedTask carries verified work forward without resuming an abandoned attempt.
public nonisolated struct StoppedTask: Sendable, Equatable {
    public let taskID: String
    public let verifiedRows: [TodoRow]
    /// Nil after a new process, where the uncertain gesture marker is unavailable.
    public let uncertainGesture: Bool?
    public let lastState: String?

    public init(taskID: String, verifiedRows: [TodoRow], uncertainGesture: Bool?, lastState: String? = nil) {
        self.taskID = taskID
        self.verifiedRows = verifiedRows
        self.uncertainGesture = uncertainGesture
        self.lastState = lastState
    }
}
