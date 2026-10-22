//
//  HouseFixture.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation
@testable import Braus

/// HouseFixture is a house of nine workers for tests that need workers in every state without a
/// store: two busy at their screens, three free, two waiting, one off, one with an attention badge
/// and one with two unread replies, and every shape among them.
enum HouseFixture {

    private typealias Row = (
        name    : String,
        status  : WorkerStatus,
        activity: String,
        role    : String,
        shape   : WorkerShape,
        badge   : HouseBadge?
    )

    private static let rows: [Row] = [
        ("Delivery",  .busy,    "Exports the stems",        "Delivers mixes to clients",   .circle,   nil),
        ("Render",    .busy,    "Renders the trailer",      "Renders and encodes video",   .triangle, .attention),
        ("Mastering", .free,    "Masters the album",        "Mixes and masters",           .capsule,  nil),
        ("Ingest",    .waiting, "Needs your OK to import",  "Sorts and imports footage",   .hexagon,  .unread(2)),
        ("Mixing",    .free,    "Rides the vocal levels",   "Balances the session",        .diamond,  nil),
        ("Design",    .free,    "Lays out the poster",      "Lays out covers and posters", .lens,     nil),
        ("Export",    .waiting, "Needs your OK to send",    "Packages files for delivery", .triangle, nil),
        ("Research",  .free,    "Collects reference mixes", "Finds references online",     .pentagon, nil),
        ("PT Agent",  .off,     "Edits the dialogue",       "Edits in Pro Tools",          .square,   nil),
    ]

    /// The house's workers, a busy one at its screen.
    static let workers: [HouseWorker] = rows.map { row in
        HouseWorker(
            id        : UUID(),
            name      : row.name,
            status    : row.status,
            activity  : row.activity,
            role      : row.role,
            shape     : row.shape,
            badge     : row.badge,
            usesScreen: row.status == .busy
        )
    }
}
