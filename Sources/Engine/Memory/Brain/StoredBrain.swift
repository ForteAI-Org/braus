import Foundation

/// StoredBrain is a consistent inspection of an application's saved observations and relations.
/// It keeps scene elements separate from the historical naming projection and makes no new claim
/// about their stability, qualification or suitability for reuse. Reading it changes no archive rows.
public struct StoredBrain: Sendable {
    public let bundleID: String
    public let projection: UIBrain
    public let scenes: [SceneDefinition]
    public let elements: [SceneElementRecord]
    public let relations: [BrainRelation]

    public init(
        bundleID: String,
        projection: UIBrain,
        scenes: [SceneDefinition] = [],
        elements: [SceneElementRecord] = [],
        relations: [BrainRelation] = []
    ) {
        self.bundleID = bundleID
        self.projection = projection
        self.scenes = scenes
        self.elements = elements
        self.relations = relations
    }

    public var hasObservations: Bool { !scenes.isEmpty || !elements.isEmpty || !relations.isEmpty }
    public var isEmpty: Bool {
        !hasObservations && projection.objects.isEmpty && projection.transitions.isEmpty
    }
}

/// StoredBrainSummary counts only the records inspected by the Brain diagnostic views.
/// An encountered application with zero records remains distinguishable from learned observations.
public struct StoredBrainSummary: Sendable {
    public let bundleID: String
    public let scenes: Int
    public let elements: Int
    public let relations: Int
    public let hasHistoricalProjection: Bool

    public init(bundleID: String, scenes: Int, elements: Int, relations: Int, hasHistoricalProjection: Bool) {
        self.bundleID = bundleID
        self.scenes = scenes
        self.elements = elements
        self.relations = relations
        self.hasHistoricalProjection = hasHistoricalProjection
    }
}
