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

    // A room's neighbours, in rows and in one or two columns, are the next two workers: no shape
    // repeats or meets a look-alike there (circle, pentagon, hexagon; square, diamond; capsule, lens).
    private static let rows: [Row] = [
        ("Delivery",  .busy,    "Exporting the AAF", .audio,  .circle,   nil),
        ("Render",    .busy,    "Rendering 42%",     .video,  .square,   .attention),
        ("Mastering", .free,    "Free",              .audio,  .capsule,  nil),
        ("Ingest",    .waiting, "Waiting for you",   .files,  .hexagon,  .unread(2)),
        ("Mixing",    .free,    "Free",              .audio,  .diamond,  nil),
        ("Design",    .free,    "Free",              .design, .lens,     nil),
        ("Export",    .waiting, "Waiting for you",   .design, .pentagon, nil),
        ("Research",  .free,    "Free",              .web,    .triangle, nil),
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
