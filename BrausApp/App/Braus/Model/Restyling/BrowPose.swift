//
//  BrowPose.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// BrowPose is where one brow sits against its resting place on the face, and which outline it holds.
///
/// Offsets are shares of the face's width, so a pose fits a mascot of any size; `dy` is positive up
/// and `rotation` is in radians, positive counter-clockwise. A nil `outline` is the state's own.
nonisolated struct BrowPose: Equatable, Sendable {
    var dx      : Double = 0
    var dy      : Double = 0
    var rotation: Double = 0
    var outline : BrowState?

    /// The brow at its resting place, holding the state's outline.
    static let rest = BrowPose()

    /// How far a brow may travel sideways, as a share of the face's width.
    static let allowedDX = -0.05...0.05

    /// How far a brow may travel down and up, as a share of the face's width.
    static let allowedDY = -0.04...0.06

    /// How far a brow may turn, in radians.
    static let allowedRotation = -0.2...0.2

    /// Whether the pose stays where a brow still reads as a brow on the face.
    var isAllowed: Bool {
        Self.allowedDX.contains(dx)
            && Self.allowedDY.contains(dy)
            && Self.allowedRotation.contains(rotation)
    }
}
