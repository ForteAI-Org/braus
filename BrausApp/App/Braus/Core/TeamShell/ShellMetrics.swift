//
//  ShellMetrics.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// ShellMetrics holds the team window's width tokens (§3.1), from which
/// `RestylingWindowLayout` divides a window between the sidebar, the
/// conversation and the inspector.
///
/// The sidebar is never hidden. It is full at `sidebar.ideal`, or compact at
/// `compactSidebar`, where the rooms stand in one column. The conversation is
/// never left less than `conversationMinimum`.
nonisolated enum ShellMetrics {

    /// How far the person may drag the full sidebar. Narrower than `minimum`
    /// its rows no longer read, and it shows the compact tiles instead.
    static let sidebar   = ColumnWidth(ideal: 280, minimum: 200, maximum: 340)
    static let inspector = ColumnWidth(ideal: 360, minimum: 320, maximum: 440)

    /// The compact sidebar: a 32 point mascot and its name under it, in a tile
    /// that clears the window's traffic lights. It is also the narrowest the
    /// person can drag the sidebar, and wide enough for the traffic lights
    /// (79 points), the toolbar's gap (17) and New Worker (36) with its 8 point
    /// inset, so the button never goes into the toolbar's overflow menu.
    static let compactSidebar: Double = 140

    /// The narrowest conversation whose bubbles still read: a short bubble is
    /// 34 ems of the 14 point body (476 points), less the margins it gives up.
    static let conversationMinimum: Double = 460

    /// How much wider than the line a resize must go before a column that gave
    /// way comes back, so a resize across the line does not flip it twice.
    static let hysteresis: Double = 24

    /// What the window shows while the person has asked for the inspector.
    struct Division: Sendable, Hashable {

        let isInspectorShown: Bool
        let isSidebarCompact: Bool

        init(isInspectorShown: Bool, isSidebarCompact: Bool) {
            self.isInspectorShown = isInspectorShown
            self.isSidebarCompact = isSidebarCompact
        }

        /// The inspector closed and the sidebar full, as every window starts.
        static let withoutInspector = Division(isInspectorShown: false, isSidebarCompact: false)
    }

    /// Whether a sidebar `width` points wide shows the compact tiles.
    static func showsCompactTiles(sidebarWidth width: Double) -> Bool {
        width < sidebar.minimum
    }
}
