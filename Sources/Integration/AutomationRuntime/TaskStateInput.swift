import EngineCore

/// TaskStateInput carries a fact from its typed producer, never from log text.
/// Reapplying a key is a no-op. Subjects are minimized target labels, never values read from a field.
public nonisolated struct TaskStateInput: Sendable, Equatable {
    public enum Fact: Sendable, Equatable {
        case request(String)
        case todo(TodoEvent)
        case callFinished(tool: String, subject: String?, outcome: Outcome?)
        case callFailed(tool: String, reason: String)
        case loaded(LoadedItem)
        case personIntervention(digest: String)
    }

    public enum LoadedItem: Sendable, Equatable {
        case schema(capability: String)
        case guide(id: String, section: String)
    }

    public enum Origin: String, Sendable { case runner, dispatcher }

    public let fact: Fact
    public let origin: Origin
    /// Dispatcher call number, starting at one per tools instance; nil for runner inputs.
    public let sequence: Int?
    /// Dispatcher keys use c<number>.<kind>; runner keys use t<turn>.request, t<turn>.person or todo.<task>.<revision>.
    public let key: String

    public init(fact: Fact, origin: Origin, sequence: Int?, key: String) {
        self.fact = fact
        self.origin = origin
        self.sequence = sequence
        self.key = key
    }
}

/// TaskStateSink applies an input inline on the main actor before a dispatched call returns.
public typealias TaskStateSink = @MainActor (TaskStateInput) -> Void
