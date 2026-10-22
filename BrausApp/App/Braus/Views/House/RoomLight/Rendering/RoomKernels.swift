//
//  RoomKernels.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Metal

/// RoomKernels is a renderer's four room kernels in RoomLight.metal: seen from above or tilted, each
/// with the worker at the centre or leaning left.
///
/// The centred kernels compile with no lean at all, so the floor plan's rooms render exactly as they
/// did before the rows leaned; the leaning ones read the lean and the worker's place from the stage.
nonisolated struct RoomKernels {
    private let centred      : MTLComputePipelineState
    private let leaning      : MTLComputePipelineState
    private let tilted       : MTLComputePipelineState
    private let tiltedLeaning: MTLComputePipelineState

    /// The kernels `verb` names with "Room", "LeaningRoom", "TiltedRoom" and "TiltedLeaningRoom",
    /// as `load` builds them, or nil when one cannot be loaded.
    init?(
        verb: String,
        load: (String) -> MTLComputePipelineState?
    ) {
        guard
            let centred       = load("\(verb)Room"),
            let leaning       = load("\(verb)LeaningRoom"),
            let tilted        = load("\(verb)TiltedRoom"),
            let tiltedLeaning = load("\(verb)TiltedLeaningRoom")
        else { return nil }
        self.centred       = centred
        self.leaning       = leaning
        self.tilted        = tilted
        self.tiltedLeaning = tiltedLeaning
    }

    /// The kernel that renders the room `uniforms` describe.
    func pipeline(for uniforms: RoomLightUniforms) -> MTLComputePipelineState {
        switch (uniforms.camera, uniforms.lean > 0) {
        case (.top, false)   : centred
        case (.top, true)    : leaning
        case (.tilted, false): tilted
        case (.tilted, true) : tiltedLeaning
        }
    }
}
