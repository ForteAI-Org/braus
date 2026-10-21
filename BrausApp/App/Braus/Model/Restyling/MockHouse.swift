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
        role    : String,
        category: AppCategory,
        shape   : WorkerShape,
        badge   : MockBadge?
    )

    // A room touches the next two rooms and, in two columns, the third after an odd one (diagonally):
    // no shape touches itself or a look-alike (circle, pentagon, hexagon; square, diamond; capsule, lens).
    private static let rows: [Row] = [
        ("Delivery",  .busy,    "Exports the stems",       "Delivers mixes to clients",   .audio,  .circle,   nil),
        ("Render",    .busy,    "Renders the trailer",     "Renders and encodes video",   .video,  .triangle, .attention),
        ("Mastering", .free,    "Free",                    "Mixes and masters",           .audio,  .capsule,  nil),
        ("Ingest",    .waiting, "Needs your OK to import", "Sorts and imports footage",   .files,  .hexagon,  .unread(2)),
        ("Mixing",    .free,    "Free",                    "Balances the session",        .audio,  .diamond,  nil),
        ("Design",    .free,    "Free",                    "Lays out covers and posters", .design, .lens,     nil),
        ("Export",    .waiting, "Needs your OK to send",   "Packages files for delivery", .design, .triangle, nil),
        ("Research",  .free,    "Free",                    "Finds references online",     .web,    .pentagon, nil),
        ("PT Agent",  .off,     "Off",                     "Edits in Pro Tools",          .audio,  .square,   nil),
    ]

    private static func worker(_ row: Row) -> MockWorker {
        MockWorker(
            id      : UUID(),
            name    : row.name,
            status  : row.status,
            activity: row.activity,
            role    : row.role,
            category: row.category,
            shape   : row.shape,
            badge   : row.badge
        )
    }
}
