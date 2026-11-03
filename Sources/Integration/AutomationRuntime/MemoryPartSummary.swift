/// MemoryPartSummary is the delivered one-line memory text, without task values, used for guide coverage.
/// ME3 supplies the same rendering the model reads; labels alone cannot establish coverage.
public nonisolated struct MemoryPartSummary: Sendable, Equatable {
    public let bundleID: String
    public let partID: String
    public let label: String
    public let text: String

    public init(bundleID: String, partID: String, label: String, text: String) {
        self.bundleID = bundleID
        self.partID = partID
        self.label = label
        self.text = text
    }
}
