//
//  ShapeOutline.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import CoreGraphics
import Foundation

/// ShapeOutline is a worker's body seen from above: a flat convex core grown by a disc of `corner`
/// radius, centred on its centroid at the origin.
///
/// Lengths are in sphere radii and y points down, as on screen and in RoomLight.metal. In three
/// dimensions the body is the core grown by a ball of `corner` radius, so its flanks are a
/// quarter-circle bevel of that radius, the same all round with no seam, and a dome of `dome`
/// height rises gently over the whole outline, so the top is never flat. The circle is a point
/// grown by one radius: the sphere. RoomLight.metal evaluates the same core from `packed`.
nonisolated struct ShapeOutline: Equatable, Sendable {

    /// Core is the flat convex figure the outline grows from.
    enum Core: Equatable, Sendable {
        /// A regular polygon around the origin, `radius` to each vertex; `turn` is the first
        /// vertex's angle, from x toward y.
        case polygon(sides: Int, radius: Double, turn: Double)

        /// A horizontal segment reaching `halfLength` to each side of the origin; a point at zero.
        case segment(halfLength: Double)

        /// The lens two circles of `radius` share, their centres `offset` above and below the
        /// origin, its tips on the x axis.
        case lens(radius: Double, offset: Double)
    }

    /// Arc is the stretch of the outline that grows from one feature of the core: a vertex, a
    /// segment's end, or a lens's arc. Grown by `growth`, its points lie at `radius + growth` from
    /// `centre` for every normal angle from `from` to `to`; the next arc starts at the same normal
    /// angle, after a straight side or at the same point.
    struct Arc: Equatable, Sendable {
        let centre: SIMD2<Double>
        let radius: Double
        let from  : Double
        let to    : Double
    }

    let core  : Core
    let corner: Double
    let dome  : Double

    /// The outline's arcs in the order of their normals' angle, clockwise on screen.
    var arcs: [Arc] {
        switch core {
        case let .polygon(sides, radius, turn):
            let half = Double.pi / Double(sides)
            return (0..<sides).map { index in
                let angle = turn + 2 * half * Double(index)
                return Arc(
                    centre: radius * SIMD2(cos(angle), sin(angle)),
                    radius: 0,
                    from  : angle - half,
                    to    : angle + half
                )
            }
        case let .segment(halfLength):
            return [
                Arc(
                    centre: SIMD2(halfLength, 0),
                    radius: 0,
                    from  : -.pi / 2,
                    to    : .pi / 2
                ),
                Arc(
                    centre: SIMD2(-halfLength, 0),
                    radius: 0,
                    from  : .pi / 2,
                    to    : 1.5 * .pi
                ),
            ]
        case let .lens(radius, offset):
            // The tips, and between them the lower and upper arcs, each centred across the axis.
            let tip  = (radius * radius - offset * offset).squareRoot()
            let edge = atan2(offset, tip)
            return [
                Arc(
                    centre: SIMD2(tip, 0),
                    radius: 0,
                    from  : -edge,
                    to    : edge
                ),
                Arc(
                    centre: SIMD2(0, -offset),
                    radius: radius,
                    from  : edge,
                    to    : .pi - edge
                ),
                Arc(
                    centre: SIMD2(-tip, 0),
                    radius: 0,
                    from  : .pi - edge,
                    to    : .pi + edge
                ),
                Arc(
                    centre: SIMD2(0, offset),
                    radius: radius,
                    from  : .pi + edge,
                    to    : 2 * .pi - edge
                ),
            ]
        }
    }

    /// The radius of the largest circle inside the outline, centred on the origin.
    var inradius: Double {
        switch core {
        case let .polygon(sides, radius, _): radius * cos(.pi / Double(sides)) + corner
        case .segment                      : corner
        case let .lens(radius, offset)     : radius - offset + corner
        }
    }

    /// The area inside the outline: Steiner's formula for a convex core grown by a disc.
    var area: Double {
        let core: (area: Double, perimeter: Double)
        switch self.core {
        case let .polygon(sides, radius, _):
            let half = Double.pi / Double(sides)
            core = (
                area     : Double(sides) * radius * radius * sin(half) * cos(half),
                perimeter: 2 * Double(sides) * radius * sin(half)
            )
        case let .segment(halfLength):
            core = (0, 4 * halfLength)
        case let .lens(radius, offset):
            let tip   = (radius * radius - offset * offset).squareRoot()
            let angle = acos(offset / radius)
            core = (2 * (radius * radius * angle - offset * tip), 4 * radius * angle)
        }
        return core.area + core.perimeter * corner + .pi * corner * corner
    }

    /// How far the outline reaches below the origin, the lowest point on screen.
    var bottom: Double {
        reach { $0.y }
    }

    /// How far the outline reaches from the origin along either axis, its half-size.
    var extent: Double {
        max(
            reach { $0.x },
            reach { -$0.x },
            reach { $0.y },
            reach { -$0.y }
        )
    }

    /// The outline scaled about its centroid so its area is the unit sphere's disc, π.
    func matchingSphere() -> ShapeOutline {
        let scale = (Double.pi / area).squareRoot()
        let core: Core
        switch self.core {
        case let .polygon(sides, radius, turn):
            core = .polygon(
                sides : sides,
                radius: radius * scale,
                turn  : turn
            )
        case let .segment(halfLength):
            core = .segment(halfLength: halfLength * scale)
        case let .lens(radius, offset):
            core = .lens(
                radius: radius * scale,
                offset: offset * scale
            )
        }
        return ShapeOutline(
            core  : core,
            corner: corner * scale,
            dome  : dome * scale
        )
    }

    /// The points of the core grown by `growth`, from 0 (the core) to `corner` (the outline), at
    /// about `pointsPerTurn` points per full turn of the normal. Every growth gives the same number
    /// of points, at the same normal angles, so outlines of two growths can be joined point to point.
    func points(
        growth       : Double,
        pointsPerTurn: Int
    ) -> [SIMD2<Double>] {
        arcs.flatMap { arc in
            let steps = max(
                2,
                Int((Double(pointsPerTurn) * (arc.to - arc.from) / (2 * .pi)).rounded(.up))
            )
            return (0...steps).map { step in
                let angle = arc.from + (arc.to - arc.from) * Double(step) / Double(steps)
                return arc.centre + (arc.radius + growth) * SIMD2(cos(angle), sin(angle))
            }
        }
    }

    /// The outline as a closed path of arcs and straight sides, through `transform` from sphere
    /// radii with y down.
    func path(transform: CGAffineTransform) -> CGPath {
        let path = CGMutablePath()
        for arc in arcs {
            // Each arc starts with a straight side from the end of the one before.
            path.addArc(
                center    : CGPoint(x: arc.centre.x, y: arc.centre.y),
                radius    : arc.radius + corner,
                startAngle: arc.from,
                endAngle  : arc.to,
                clockwise : false,
                transform : transform
            )
        }
        path.closeSubpath()
        return path
    }

    /// The outline as RoomLight.metal reads it: the sides (0 for a segment, 2 for a lens), the
    /// core's size (vertex radius, half length or lens radius), its turn or lens offset, and the
    /// corner radius.
    var packed: SIMD4<Float> {
        switch core {
        case let .polygon(sides, radius, turn):
            SIMD4(Float(sides), Float(radius), Float(turn), Float(corner))
        case let .segment(halfLength):
            SIMD4(0, Float(halfLength), 0, Float(corner))
        case let .lens(radius, offset):
            SIMD4(2, Float(radius), Float(offset), Float(corner))
        }
    }

    /// The farthest the outline reaches along `axis`, a linear map of a point: over every arc, its
    /// ends and the normal angles inside it where the outline turns along the axis.
    private func reach(_ axis: (SIMD2<Double>) -> Double) -> Double {
        arcs.map { arc in
            let turns = (-4...8).map { Double($0) * .pi / 2 }.filter { $0 > arc.from && $0 < arc.to }
            return ([arc.from, arc.to] + turns).map { angle in
                axis(arc.centre + (arc.radius + corner) * SIMD2(cos(angle), sin(angle)))
            }.max() ?? 0
        }.max() ?? 0
    }
}
