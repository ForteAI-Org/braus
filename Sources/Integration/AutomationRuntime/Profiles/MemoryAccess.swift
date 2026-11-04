
/// MemoryAccess carries immutable session permissions to each request and recorder.
public nonisolated struct MemoryAccess: Sendable, Equatable {
    public let reads: Bool
    public let learns: Bool
    public let enrichesScenes: Bool
    public var teachesBrain: Bool { learns }

    public init(reads: Bool, learns: Bool, enrichesScenes: Bool) {
        self.reads = reads
        self.learns = learns
        self.enrichesScenes = enrichesScenes
    }

    public static let readLearn = MemoryAccess(reads: true, learns: true, enrichesScenes: true)

    /// Carries the caller's permissions through session adapters without changing shared memory state.
    @TaskLocal public static var current: MemoryAccess = .readLearn
}
