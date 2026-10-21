//
//  HouseInspectorMetrics.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseInspectorMetrics are the inspector's spacings, in points: the system's grouped form
/// proportions (10 pt corners, rows inset from the box as far as the title is) with more room
/// between sections, inside rows and from the column's edges.
enum HouseInspectorMetrics {

    /// From the column's sides to the boxes.
    static let edgeInset: CGFloat = 24

    /// Above the first section and below the last.
    static let verticalInset: CGFloat = 18

    /// From one section's box to the next section's title.
    static let sectionSpacing: CGFloat = 30

    /// The title row of a section.
    static let headerHeight: CGFloat = 30

    /// From a section's title to its box.
    static let headerGap: CGFloat = 6

    /// From the box's sides to a row's content, and the title's inset, which lines up with it.
    static let rowInset: CGFloat = 14

    /// Above and below a row's content.
    static let rowPadding: CGFloat = 11

    /// The shortest row, so one line of text stands as tall as a row with a control.
    static let rowMinimumHeight: CGFloat = 20

    /// The box's corners, as the system's grouped form draws them.
    static let cornerRadius: CGFloat = 10

    /// The fill of a section's box over the inspector's ground.
    static let boxFill = Color(nsColor: .quaternarySystemFill)

    /// The box behind a section's rows.
    static var box: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: cornerRadius,
            style       : .continuous
        )
    }
}
