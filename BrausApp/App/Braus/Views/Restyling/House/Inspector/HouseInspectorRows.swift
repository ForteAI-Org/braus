//
//  HouseInspectorRows.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseInspectorRows lays out a section's rows as the system's grouped form does, one under the
/// other with a separator between them, a label at the leading edge and its value in the secondary
/// tone at the trailing one. The caller draws the box behind them (`HouseInspectorMetrics.box`).
///
/// It stands in for `Form` because a form's rows cannot fold smoothly: the table under it inserts
/// and removes them with jumps (`HouseFoldableSection`).
struct HouseInspectorRows<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group(subviews: content()) { rows in
            VStack(
                alignment: .leading,
                spacing  : 0
            ) {
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Divider()
                            .padding(
                                .horizontal,
                                HouseInspectorMetrics.rowInset
                            )
                    }
                    row
                        .frame(
                            maxWidth : .infinity,
                            minHeight: HouseInspectorMetrics.rowMinimumHeight,
                            alignment: .leading
                        )
                        .padding(
                            .horizontal,
                            HouseInspectorMetrics.rowInset
                        )
                        .padding(
                            .vertical,
                            HouseInspectorMetrics.rowPadding
                        )
                }
            }
        }
        .labeledContentStyle(RowStyle())
    }

    /// RowStyle is a labelled row as the grouped form shows it: the label leading, the value
    /// trailing in the secondary tone.
    private struct RowStyle: LabeledContentStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(
                alignment: .firstTextBaseline,
                spacing  : 12
            ) {
                configuration.label
                Spacer(minLength: 0)
                configuration.content
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
