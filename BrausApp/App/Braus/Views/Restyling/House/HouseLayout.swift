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

    /// The gap between rooms, across and down.
    static let gap: CGFloat = 6

    /// How many columns of rooms a sidebar `sidebarWidth` points wide holds: one exactly when it
    /// shows the compact tiles, two otherwise.
    static func columns(sidebarWidth: CGFloat) -> Int {
        ShellMetrics.showsCompactTiles(sidebarWidth: sidebarWidth) ? 1 : 2
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
