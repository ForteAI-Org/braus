//
//  BodyPose.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// BodyPose is where a worker's body stands against rest in its room as its behaviour moves it: turned
/// sideways about its foot (`tilt`, radians, its top toward the right) and leaning toward the camera
/// (`lean`, radians), off the floor (`hop`), across (`shift`, toward the right) and toward the camera
/// (`slide`), as shares of the room's short side, and taller or squatter (`stretch`, a share of its
/// height, keeping its volume).
///
/// A room bakes each pose its worker takes into frames, so the poses a behaviour uses are few and
/// exact; they stay within the limits below, soft enough for a body that is only idling.
nonisolated struct BodyPose: Hashable, Sendable {
    var tilt   : Double = 0
    var lean   : Double = 0
    var hop    : Double = 0
    var shift  : Double = 0
    var slide  : Double = 0
    var stretch: Double = 0

    static let rest = BodyPose()

    /// The most a body turns either way, in radians, hops, shifts or slides, as shares of the room's
    /// short side, and stretches or squats, as a share of its height.
    static let maxTurn    = 8 * Double.pi / 180
    static let maxHop     = 0.05
    static let maxMove    = 0.04
    static let maxStretch = 0.08

    /// Whether the pose stays within the limits.
    var isAllowed: Bool {
        abs(tilt) <= Self.maxTurn && abs(lean) <= Self.maxTurn && (0...Self.maxHop).contains(hop)
            && abs(shift) <= Self.maxMove && abs(slide) <= Self.maxMove && abs(stretch) <= Self.maxStretch
    }

    /// The pose `share` of the way from rest.
    func scaled(_ share: Double) -> BodyPose {
        BodyPose(
            tilt   : tilt * share,
            lean   : lean * share,
            hop    : hop * share,
            shift  : shift * share,
            slide  : slide * share,
            stretch: stretch * share
        )
    }
}
