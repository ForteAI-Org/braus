import Foundation
import InteractionObservation

/// HumanReadProvenance preserves per-surface pixel, AX and semantic intervals in listener-clock seconds.
/// A retry is another attempt; a failed surface never borrows a successful surface's intervals or state.
nonisolated struct HumanReadProvenance: Codable, Sendable {
    struct Surface: Codable, Sendable {
        let processID: Int32
        let windowNumber: Int
        let mode: String
        var capture: InteractionSemanticSnapshot.Interval?
        var accessibility: InteractionSemanticSnapshot.Interval?
        var semantics: InteractionSemanticSnapshot?
        var failed = false
        /// The structural read taken with this surface; absent before archive version 3.
        var structure: InteractionStructuralRead?
    }

    /// A structural read taken when the person paused after the read of the action `sequence`.
    struct Settled: Codable, Sendable {
        let sequence: UInt64
        let structure: InteractionStructuralRead
    }

    let version: Int
    var surfaces: [Surface]
    var firstOverlappingSequence: UInt64?
    var lastOverlappingSequence: UInt64?
    /// On the final read: the structural read taken when control passed to the person, the "before" of every
    /// structural effect; absent in older archives and when input arrived during it.
    var initialStructure: InteractionStructuralRead?
    /// On the final read: the structural reads taken when the person paused, each after the read it settles.
    var settled: [Settled]?

    init(surfaces: [Surface] = []) { version = 1; self.surfaces = surfaces }
}
