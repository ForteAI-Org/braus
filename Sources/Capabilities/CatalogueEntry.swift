/// CatalogueEntry pairs a strict capability contract with the questions used to discover it.
/// The composition supplies descriptions and examples; this value owns no transport or session state.
public struct CatalogueEntry: Sendable, Equatable {
    public let contract: CapabilityContract
    public let exampleQuestions: [String]

    /// Identifies the strict schema format supplied by the catalogue composition.
    public var isStrict: Bool { true }

    public init(
        contract: CapabilityContract,
        exampleQuestions: [String]
    ) {
        self.contract = contract
        self.exampleQuestions = exampleQuestions
    }
}
