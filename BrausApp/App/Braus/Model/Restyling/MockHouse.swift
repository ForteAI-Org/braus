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
        workers      : rows.enumerated().map(worker),
        archivedCount: 3,
        mostUsed     : ["Delivery", "Ingest", "Research", "Render"]
    )

    private typealias Row = (
        name    : String,
        status  : WorkerStatus,
        activity: String,
        category: AppCategory,
        badge   : MockBadge?
    )

    private static let rows: [Row] = [
        ("Delivery",  .busy,    "Exporting the AAF", .audio,  nil),
        ("Render",    .busy,    "Rendering 42%",     .video,  .attention),
        ("Mastering", .free,    "Free",              .audio,  nil),
        ("Ingest",    .waiting, "Waiting for you",   .files,  .unread(2)),
        ("Mixing",    .free,    "Free",              .audio,  nil),
        ("Design",    .free,    "Free",              .design, nil),
        ("Export",    .waiting, "Waiting for you",   .design, nil),
        ("Research",  .free,    "Free",              .web,    nil),
        ("PT Agent",  .off,     "Off",               .audio,  nil),
    ]

    /// A worker whose appearance follows its place in the house: the palette
    /// cycles through `MascotPalette.all` and the seed picks a hue inside it,
    /// so every worker gets its own tint.
    private static func worker(
        _ index: Int,
        _ row  : Row
    ) -> MockWorker {
        let palettes = MascotPalette.all
        let appearance = WorkerAppearance(
            seed            : Int64(index + 1) * 7_919,
            generatorVersion: MascotDrawing.generatorVersion,
            palette         : palettes[index % palettes.count].name
        )
        return MockWorker(
            id        : UUID(),
            name      : row.name,
            status    : row.status,
            activity  : row.activity,
            category  : row.category,
            appearance: appearance,
            badge     : row.badge
        )
    }
}
