//
//  RestylingWindowLayout.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// RestylingWindowLayout reserves the conversation's minimum beside the columns' ideal widths.
/// Column ranges depend only on the division, so resizing within one division does not update
/// split item constraints. The split can shrink wider dragged columns toward their ideals.
/// Decisions use window width, never a measurement inside the split.
nonisolated enum RestylingWindowLayout {

    /// What the house's split shows, always: the sidebar never closes.
    static let columnVisibility = NavigationSplitViewVisibility.all

    static let minimumWidth = ShellMetrics.compactSidebar + ShellMetrics.conversationMinimum

    static let inspectorWidth = ShellMetrics.inspector

    private static let fullSidebarWidth = ColumnWidth(
        ideal  : ShellMetrics.sidebar.ideal,
        minimum: ShellMetrics.compactSidebar,
        maximum: ShellMetrics.sidebar.maximum
    )

    private static let compactSidebarWidth = ColumnWidth(
        ideal  : ShellMetrics.compactSidebar,
        minimum: ShellMetrics.compactSidebar,
        maximum: ShellMetrics.compactSidebar
    )

    /// Keeps columns while their ideal widths fit. A returning column needs the shared
    /// hysteresis margin; a first report or an explicit inspector request has no return margin.
    static func division(
        window              : Double,
        isInspectorRequested: Bool,
        previous            : ShellMetrics.Division?
    ) -> ShellMetrics.Division {
        if isInspectorRequested {
            let full = ShellMetrics.Division(
                isInspectorShown: true,
                isSidebarCompact: false
            )
            let fullMargin = margin(
                previous,
                kept: previous == full
            )
            let fullMinimum = fullSidebarWidth.ideal + inspectorWidth.ideal + ShellMetrics.conversationMinimum
            if window >= fullMinimum + fullMargin { return full }

            let compactMargin = margin(
                previous,
                kept: previous?.isInspectorShown == true
            )
            let compactMinimum = compactSidebarWidth.ideal + inspectorWidth.ideal + ShellMetrics.conversationMinimum
            if window >= compactMinimum + compactMargin {
                return ShellMetrics.Division(
                    isInspectorShown: true,
                    isSidebarCompact: true
                )
            }
        }

        let fullMargin = margin(
            previous,
            kept: previous?.isSidebarCompact == false
        )
        let fullMinimum = fullSidebarWidth.ideal + ShellMetrics.conversationMinimum
        return ShellMetrics.Division(
            isInspectorShown: false,
            isSidebarCompact: window < fullMinimum + fullMargin
        )
    }

    static func sidebarWidth(for division: ShellMetrics.Division) -> ColumnWidth {
        division.isSidebarCompact ? compactSidebarWidth : fullSidebarWidth
    }

    private static func margin(
        _ previous: ShellMetrics.Division?,
        kept      : Bool
    ) -> Double {
        previous == nil || kept ? 0 : ShellMetrics.hysteresis
    }
}
