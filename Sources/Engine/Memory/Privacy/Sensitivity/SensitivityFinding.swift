/// SensitivityFinding locates a sensitive span in the original free text.
public struct SensitivityFinding: Sendable, Equatable {
    public let range: Range<String.Index>
    public let verdict: SensitivityVerdict
}
