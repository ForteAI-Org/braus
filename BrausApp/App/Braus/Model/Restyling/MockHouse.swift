//
//  MockHouse.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// MockHouse is the simulated team the restyling mockup shows.
nonisolated struct MockHouse: Sendable {
    var workers      : [HouseWorker]
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
        badge   : HouseBadge?
    )

    // A room touches the next two rooms and, in two columns, the third after an odd one (diagonally):
    // no shape touches itself or a look-alike (circle, pentagon, hexagon; square, diamond; capsule, lens).
    private static let rows: [Row] = [
        ("Delivery",  .busy,    "Exports the stems",        "Delivers mixes to clients",   .audio,  .circle,   nil),
        ("Render",    .busy,    "Renders the trailer",      "Renders and encodes video",   .video,  .triangle, .attention),
        ("Mastering", .free,    "Masters the album",        "Mixes and masters",           .audio,  .capsule,  nil),
        ("Ingest",    .waiting, "Needs your OK to import",  "Sorts and imports footage",   .files,  .hexagon,  .unread(2)),
        ("Mixing",    .free,    "Rides the vocal levels",   "Balances the session",        .audio,  .diamond,  nil),
        ("Design",    .free,    "Lays out the poster",      "Lays out covers and posters", .design, .lens,     nil),
        ("Export",    .waiting, "Needs your OK to send",    "Packages files for delivery", .design, .triangle, nil),
        ("Research",  .free,    "Collects reference mixes", "Finds references online",     .web,    .pentagon, nil),
        ("PT Agent",  .off,     "Edits the dialogue",       "Edits in Pro Tools",          .audio,  .square,   nil),
    ]

    /// Adds a worker the person created, free and with nothing to do yet, after the others, and
    /// returns its id. A role left empty stays empty, as the app's own does.
    mutating func add(
        name : String,
        role : String,
        shape: WorkerShape
    ) -> HouseWorker.ID {
        let worker = HouseWorker(
            id        : UUID(),
            name      : name,
            status    : .free,
            activity  : "",
            role      : role,
            category  : .general,
            shape     : shape,
            badge     : nil,
            usesScreen: false
        )
        workers.append(worker)
        return worker.id
    }

    /// The shape a new worker starts with: one no worker has when there is one, otherwise one of the
    /// least used; `seed` picks among them, so each new worker may start differently.
    func suggestedShape(seed: UInt64) -> WorkerShape {
        let uses       = Dictionary(grouping: workers.map(\.shape)) { $0 }.mapValues(\.count)
        let fewest     = WorkerShape.allCases.map { uses[$0, default: 0] }.min() ?? 0
        let candidates = WorkerShape.allCases.filter { uses[$0, default: 0] == fewest }
        return candidates[Int(seed % UInt64(candidates.count))]
    }

    private static func worker(_ row: Row) -> HouseWorker {
        // A simulated busy worker sits at its screen.
        HouseWorker(
            id        : UUID(),
            name      : row.name,
            status    : row.status,
            activity  : row.activity,
            role      : row.role,
            category  : row.category,
            shape     : row.shape,
            badge     : row.badge,
            usesScreen: row.status == .busy
        )
    }
}
