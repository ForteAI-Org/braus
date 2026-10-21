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
    /// rows keep one and only their width changes. It holds the worker with its name and subtitle
    /// beside it.
    static let rowHeight: CGFloat = 72

    /// The height the worker's name takes at a room's foot.
    static let nameBand: CGFloat = 22

    /// The gap between a wide row's worker and its name beside it.
    static let nameGap: CGFloat = 12

    /// The space between the rooms and the sidebar's edges. Wider, the compact rooms would be too
    /// narrow for the plaque's text.
    static let margin: CGFloat = 10

    /// The gap between rooms, across and down: wide enough for each room's spilled light
    /// (`RoomOpeningView`) to show around it without reaching a neighbour.
    static let gap: CGFloat = 12

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

    /// How a room or row added to the house comes in: a short fade of its own, so the rooms around it
    /// take their places at once and a room chosen there can be scrolled to in the same moment.
    static var arrival: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.25)),
            removal  : .identity
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
