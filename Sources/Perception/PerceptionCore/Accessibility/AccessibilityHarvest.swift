//
//  AccessibilityHarvest.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// AccessibilityHarvest is what one accessibility read of a window answers: the elements it
/// harvested, read-only fields past the edge and the quality of their read. They travel together because the
/// elements alone cannot say whether the walk finished: an empty list is a real answer from an
/// application that exposes nothing, and also what a denied grant or a missing window produces.
public struct AccessibilityHarvest: Sendable, Equatable {

    public var elements: [SceneElement]
    /// Named fields with readable values but no trusted click target.
    public var outOfViewFields: [OutOfViewField]
    public var quality: CaptureQuality
    /// Canvases no element covers (`UncoveredAreas`), labeled after the element canvases in `elements`.
    /// Each is a canvas only once its pixels show structure, which `ScenePipeline` decides.
    public var uncoveredCanvases: [SceneElement]

    public init(
        elements         : [SceneElement],
        quality          : CaptureQuality,
        outOfViewFields  : [OutOfViewField] = [],
        uncoveredCanvases: [SceneElement] = []
    ) {
        self.outOfViewFields   = outOfViewFields
        self.elements          = elements
        self.quality           = quality
        self.uncoveredCanvases = uncoveredCanvases
    }

    /// No read took place: no elements, quality unknown.
    public static let none = AccessibilityHarvest(elements: [], quality: .unknown)
}
