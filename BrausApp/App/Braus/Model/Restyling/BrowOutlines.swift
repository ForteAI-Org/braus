//
//  BrowOutlines.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// BrowOutlines holds each brow's closed outline per state, 320 points in the 240 × 170 artboard.
/// Every outline has the same point count, so two states morph point by point.
nonisolated struct BrowOutlines: Sendable {
    let left : [BrowState: [CGPoint]]
    let right: [BrowState: [CGPoint]]

    /// The outlines shipped in the app bundle. A missing or unreadable resource yields no outlines
    /// rather than a crash, so callers find no outline for any state; the tests catch the missing file.
    static let bundled: BrowOutlines = {
        let url = Bundle.main.url(
            forResource  : "BrowOutlines",
            withExtension: "json"
        )
        guard let url, let outlines = try? load(from: url) else {
            return BrowOutlines(
                left : [:],
                right: [:]
            )
        }
        return outlines
    }()

    /// Reads outlines from the prototype's JSON: `{"STATE": {"L": [[x, y], …], "R": [[x, y], …]}}`.
    /// Keys that name no state are skipped.
    static func load(from url: URL) throws -> BrowOutlines {
        let sides = try JSONDecoder().decode(
            [String: [String: [CGPoint]]].self,
            from: Data(contentsOf: url)
        )
        var left : [BrowState: [CGPoint]] = [:]
        var right: [BrowState: [CGPoint]] = [:]
        for (key, side) in sides {
            guard let state = BrowState(rawValue: key) else { continue }
            left[state]  = side["L"]
            right[state] = side["R"]
        }
        return BrowOutlines(
            left : left,
            right: right
        )
    }
}
