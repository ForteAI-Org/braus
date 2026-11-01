/// FieldSignals describes a field without retaining its value.
public struct FieldSignals: Sendable, Equatable, Codable {
    public var role: String?
    public var subrole: String?
    public var labels: [String]
    public var declaredSecret: Bool
    public var bundleID: String?
    public var isContent: Bool
    public var markupDeclaresSecret: Bool

    public init(
        role: String? = nil,
        subrole: String? = nil,
        labels: [String] = [],
        declaredSecret: Bool = false,
        bundleID: String? = nil,
        isContent: Bool = false,
        markupDeclaresSecret: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.labels = labels
        self.declaredSecret = declaredSecret
        self.bundleID = bundleID
        self.isContent = isContent
        self.markupDeclaresSecret = markupDeclaresSecret
    }
}
