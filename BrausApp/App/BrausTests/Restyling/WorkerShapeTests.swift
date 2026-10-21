//
//  WorkerShapeTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import Braus

@Suite("WorkerShape")
struct WorkerShapeTests {

    @Test("Derived shapes keep fixed UUID mappings across launches")
    func derivedShapes() throws {
        let fixtures: [(String, WorkerShape)] = [
            ("00000000-0000-0000-0000-000000000000", .circle),
            ("00000000-0000-0000-0000-000000000001", .square),
            ("00000000-0000-0000-0000-000000000007", .lens),
            ("00000000-0000-0000-0000-000000000008", .circle),
            ("01000000-0000-0000-0000-000000000001", .triangle),
            ("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", .circle),
        ]
        for (text, expected) in fixtures {
            let id = try #require(UUID(uuidString: text))
            #expect(WorkerShape.derived(from: id) == expected)
        }
    }

    @Test("Every outline is one closed loop, centred on its centroid and as large as the sphere")
    func outlines() throws {
        for shape in WorkerShape.allCases {
            let outline = shape.outline
            var points   = [CGPoint]()
            var moves    = 0
            var isClosed = false
            outline.path(transform: .identity).flattened(threshold: 1e-4).applyWithBlock { element in
                switch element.pointee.type {
                case .moveToPoint:
                    moves += 1
                    points.append(element.pointee.points[0])
                case .addLineToPoint:
                    points.append(element.pointee.points[0])
                case .closeSubpath:
                    isClosed = true
                default:
                    break
                }
            }
            #expect(moves == 1 && isClosed, "\(shape)")
            // No jump across the shape: every arc meets the next through a side, at most the triangle's.
            let steps = zip(points, points.dropFirst() + points.prefix(1)).map { hypot($1.x - $0.x, $1.y - $0.y) }
            #expect((steps.max() ?? .infinity) < 1.6, "\(shape)")

            // The shoelace area and centroid of the flattened loop.
            var area   = 0.0
            var centre = CGPoint.zero
            for (point, next) in zip(points, points.dropFirst() + points.prefix(1)) {
                let cross = point.x * next.y - next.x * point.y
                area     += cross / 2
                centre.x += (point.x + next.x) * cross / 6
                centre.y += (point.y + next.y) * cross / 6
            }
            #expect(abs(abs(area) / .pi - 1) <= 0.1, "\(shape): \(abs(area))")
            #expect(abs(abs(area) - outline.area) < 1e-3 * outline.area, "\(shape)")
            #expect(hypot(centre.x / area, centre.y / area) < 1e-3, "\(shape)")
        }
    }

    @Test("The circle is the sphere: a point grown by one radius, with no dome")
    func circle() {
        let circle = WorkerShape.circle.outline
        #expect(circle.core == .segment(halfLength: 0))
        #expect(circle.corner == 1 && circle.dome == 0)
        #expect(circle.inradius == 1 && abs(circle.extent - 1) < 1e-12 && abs(circle.bottom - 1) < 1e-12)
    }

    @Test("A gentle dome tops every shape with a flat core; the circle and the capsule have none")
    func domes() {
        for shape in WorkerShape.allCases {
            let outline = shape.outline
            if shape == .circle || shape == .capsule {
                #expect(outline.dome == 0, "\(shape)")
            } else {
                #expect(outline.dome > 0 && outline.dome < 0.5 * outline.inradius, "\(shape)")
            }
        }
    }
}
