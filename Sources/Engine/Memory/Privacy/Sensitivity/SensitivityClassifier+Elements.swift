import PerceptionCore

extension SensitivityClassifier {
    /// Classifies an observed scene element, including the structural content signal.
    /// Native unreadable subroles have already been refused before values enter a scene.
    public func classify(_ element: SceneElement) -> SensitivityVerdict {
        classify(element.value, in: .init(role: element.role, subrole: "", labels: [element.label],
                                          isContent: ConfidentialSurfaces.isContent(element)))
    }

    /// Classifies the same observed facts after they have been prepared for storage.
    public func classify(_ element: CaptureElement) -> SensitivityVerdict {
        classify(nil, in: .init(role: element.role, subrole: "", labels: [element.label],
                                          isContent: ConfidentialSurfaces.isContent(element)))
    }
}
