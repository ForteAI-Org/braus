/// SceneContextHold retains revisions from a boundary and, optionally, one earlier scene carried across a switch.
nonisolated public struct SceneContextHold: Sendable, Equatable {
    public let firstHeldRevision: Int
    public let keptRevision: Int?
    public let reason: SceneContextReset

    public init(firstHeldRevision: Int, keptRevision: Int? = nil, reason: SceneContextReset) {
        self.firstHeldRevision = firstHeldRevision
        self.keptRevision = keptRevision
        self.reason = reason
    }

    func contains(_ revision: Int) -> Bool {
        revision >= firstHeldRevision || revision == keptRevision
    }
}
