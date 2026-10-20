//
//  HouseLayout.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseLayout is the geometry and the light colour the house's rooms and rows share, after the
/// design's prototype.
nonisolated enum HouseLayout {

    /// A room's height in the full sidebar and in the compact one.
    static let roomHeight       : CGFloat = 104
    static let compactRoomHeight: CGFloat = 92

    /// A row's height, wide or compact: the list does not animate a change of row height, so the
    /// rows keep one and only their width changes.
    static let rowHeight: CGFloat = 84

    /// The space between the rooms and the sidebar's edges.
    static let margin: CGFloat = 10

    /// The gap between rooms, across and down.
    static let gap: CGFloat = 6

    /// How many columns of rooms a sidebar `sidebarWidth` points wide holds: one exactly when it
    /// shows the compact tiles, two otherwise.
    static func columns(sidebarWidth: CGFloat) -> Int {
        ShellMetrics.showsCompactTiles(sidebarWidth: sidebarWidth) ? 1 : 2
    }

    /// How rooms and rows reshape between the wide sidebar and the compact one: a spring that moves
    /// and resizes each of them, or nil under Reduce Motion, where the sidebar cross-fades instead.
    static func reshaping(reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .spring(
            duration: 0.4,
            bounce  : 0.12
        )
    }

    /// The colour of `status`'s light; a worker that is off shows a dim grey.
    static func light(of status: WorkerStatus) -> Color {
        guard let light = status.light else {
            return Color(
                red  : 120.0 / 255,
                green: 120.0 / 255,
                blue : 124.0 / 255
            )
        }
        return Color(
            red  : light.red,
            green: light.green,
            blue : light.blue
        )
    }
}
