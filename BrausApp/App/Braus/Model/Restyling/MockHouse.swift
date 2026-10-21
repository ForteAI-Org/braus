//
//  MockHouse.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// MockHouse is the simulated team the restyling mockup shows.
nonisolated struct MockHouse: Sendable {
    var workers      : [MockWorker]
    var archivedCount: Int
    var mostUsed     : [String]

    /// The house of the design's prototypes.
    static let sample = MockHouse(
        workers      : rows.map(worker),
        archivedCount: 3,
        mostUsed     : ["Delivery", "Ingest", "Research", "Render"]
    )

    private typealias Row = (
        name    : String,
        status  : WorkerStatus,
        activity: String,
        category: AppCategory,
        shape   : WorkerShape,
        badge   : MockBadge?
    )

    // A room touches the next two rooms and, in two columns, the third after an odd one (diagonally):
    // no shape touches itself or a look-alike (circle, pentagon, hexagon; square, diamond; capsule, lens).
    private static let rows: [Row] = [
        ("Delivery",  .busy,    "Exporting the AAF", .audio,  .circle,   nil),
        ("Render",    .busy,    "Rendering 42%",     .video,  .triangle, .attention),
        ("Mastering", .free,    "Free",              .audio,  .capsule,  nil),
        ("Ingest",    .waiting, "Waiting for you",   .files,  .hexagon,  .unread(2)),
        ("Mixing",    .free,    "Free",              .audio,  .diamond,  nil),
        ("Design",    .free,    "Free",              .design, .lens,     nil),
        ("Export",    .waiting, "Waiting for you",   .design, .triangle, nil),
        ("Research",  .free,    "Free",              .web,    .pentagon, nil),
        ("PT Agent",  .off,     "Off",               .audio,  .square,   nil),
    ]

    private static func worker(_ row: Row) -> MockWorker {
        MockWorker(
            id      : UUID(),
            name    : row.name,
            status  : row.status,
            activity: row.activity,
            category: row.category,
            shape   : row.shape,
            badge   : row.badge
        )
    }
}
