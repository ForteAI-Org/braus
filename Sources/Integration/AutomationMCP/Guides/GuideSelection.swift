/// GuideSelection contains whole sections and typed evidence of sections superseded by memory.
public nonisolated struct GuideSelection: Sendable {
    public let sections: [AppGuide.Section]
    public let overlaps: [GuideOverlap]
    public let leftOut: Int

    public init(sections: [AppGuide.Section], overlaps: [GuideOverlap], leftOut: Int = 0) {
        self.sections = sections
        self.overlaps = overlaps
        self.leftOut = leftOut
    }
}

/// GuideOverlap reports coverage without inferring agreement or contradiction.
public nonisolated struct GuideOverlap: Sendable {
    public enum Contrast: Sendable { case unknown }
    public let section: String
    public let memoryPartID: String
    public let similarity: Double
    public let contrast: Contrast
}
