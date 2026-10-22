//
//  WorkerShape.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// WorkerShape is what tells one worker from another: every body is the same dark graphite metal,
/// and only its outline seen from above differs.
///
/// Eight clean geometric outlines with generously rounded corners, each with the sphere's area,
/// so they weigh the same, and centred on its centroid. The polygons' corners are as round as the
/// outline stays legible at 16 points: tighter on the pentagon and hexagon, which otherwise read as
/// circles. A gentle dome a third of the inradius high keeps every top from looking flat.
nonisolated enum WorkerShape: String, CaseIterable, Sendable {
    case circle, square, triangle, diamond, pentagon, hexagon, capsule, lens

    /// WorkerShape derives a stable default by summing the UUID's bytes.
    /// Unlike Swift's randomized Hasher, this mapping survives process restarts.
    static func derived(from id: UUID) -> WorkerShape {
        let sum = withUnsafeBytes(of: id.uuid) { bytes in
            bytes.reduce(0) { $0 + Int($1) }
        }
        return allCases[sum % allCases.count]
    }

    /// The shape a new worker starts with: one that none of `taken` has when there is one, otherwise
    /// one of the least used; `seed` picks among them, so each new worker may start differently.
    static func suggested(
        avoiding taken: [WorkerShape],
        seed          : UInt64
    ) -> WorkerShape {
        let uses       = Dictionary(grouping: taken) { $0 }.mapValues(\.count)
        let fewest     = allCases.map { uses[$0, default: 0] }.min() ?? 0
        let candidates = allCases.filter { uses[$0, default: 0] == fewest }
        return candidates[Int(seed % UInt64(candidates.count))]
    }

    /// The shape's name, as the shape picker and VoiceOver say it.
    var name: String { String(describing: self).capitalized }

    /// The outline in sphere radii, y down.
    var outline: ShapeOutline {
        switch self {
        case .circle  : Self.circleOutline
        case .square  : Self.squareOutline
        case .triangle: Self.triangleOutline
        case .diamond : Self.diamondOutline
        case .pentagon: Self.pentagonOutline
        case .hexagon : Self.hexagonOutline
        case .capsule : Self.capsuleOutline
        case .lens    : Self.lensOutline
        }
    }

    /// The dome's height, as a share of the inradius.
    private static let domeShare = 0.3

    /// A point grown by one radius: today's sphere, with no dome.
    private static let circleOutline = ShapeOutline(
        core  : .segment(halfLength: 0),
        corner: 1,
        dome  : 0
    )

    /// A squircle-like rounded square, its corners half its inradius.
    private static let squareOutline = polygon(
        4,
        turn  : .pi / 4,
        corner: 0.5
    )

    /// An equilateral triangle, point up, its corners half its inradius.
    private static let triangleOutline = polygon(
        3,
        turn  : -.pi / 2,
        corner: 0.5
    )

    /// A rounded square turned 45°, its points a little sharper than the square's corners.
    private static let diamondOutline = polygon(
        4,
        turn  : -.pi / 2,
        corner: 0.42
    )

    private static let pentagonOutline = polygon(
        5,
        turn  : -.pi / 2,
        corner: 0.35
    )

    /// A hexagon with flat top and bottom, which tell it from the circle.
    private static let hexagonOutline = polygon(
        6,
        turn  : 0,
        corner: 0.28
    )

    /// A horizontal stadium half again as wide as tall; its rounded ridge is never flat, so no dome.
    private static let capsuleOutline = ShapeOutline(
        core  : .segment(halfLength: 0.5),
        corner: 1,
        dome  : 0
    ).matchingSphere()

    /// A horizontal vesica, its tips rounded a little.
    private static let lensOutline = ShapeOutline(
        core  : .lens(
            radius: 1,
            offset: 0.6
        ),
        corner: 0.15,
        dome  : domeShare * (1 - 0.6 + 0.15)
    ).matchingSphere()

    /// A regular polygon with inradius 1 before scaling, `corner` of it the corners' radius.
    private static func polygon(
        _ sides: Int,
        turn   : Double,
        corner : Double
    ) -> ShapeOutline {
        ShapeOutline(
            core  : .polygon(
                sides : sides,
                radius: (1 - corner) / cos(.pi / Double(sides)),
                turn  : turn
            ),
            corner: corner,
            dome  : domeShare
        ).matchingSphere()
    }
}
