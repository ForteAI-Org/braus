//
//  InspectorTurnSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// The worker's current or last turn as it ran, from the reading the
/// inspector keeps: the model and effort it ran with, when it started and
/// how it ended. Given `isExpanded`, the section folds under its title.
struct InspectorTurnSection: View {

    let workerName: String
    let turn      : WorkerInspectorView.TurnReading

    var isExpanded: Binding<Bool>?

    var body: some View {
        if let isExpanded {
            Section(
                turnTitle,
                isExpanded: isExpanded
            ) {
                turnRows
            }
        } else {
            Section(turnTitle) { turnRows }
        }
    }

    private var turnTitle: String {
        if case .read(let summary) = turn, summary.state == .running { return "Current Turn" }

        return "Last Turn"
    }

    @ViewBuilder
    private var turnRows: some View {
        switch turn {
        case .reading:
            // Placeholders in the rows' own shape while the turn is read, never a spinning wheel.
            Group {
                LabeledContent(
                    "Model",
                    value: "Model and Effort"
                )
                LabeledContent(
                    "Started",
                    value: "a moment ago"
                )
                LabeledContent(
                    "Result",
                    value: "Completed"
                )
            }
            .redacted(reason: .placeholder)
            .shimmering()
            .accessibilityLabel("Loading turn details")

        case .nothingYet:
            Text("Turn details appear after \(workerName) responds.")
                .foregroundStyle(.secondary)

        case .read(let summary):
            // What the turn ran with, which can differ from the profile above once it changes.
            LabeledContent(
                "Model",
                value: summary.modelLine
            )
            LabeledContent("Started") {
                Text(
                    summary.startedAt,
                    format: .relative(presentation: .named)
                )
            }
            .help(summary.startedAt.formatted(
                date: .abbreviated,
                time: .shortened
            ))
            LabeledContent("Result") { outcome(summary) }

        case .failed(let reason):
            Label(
                "Couldn’t load the last turn. Details: \(reason)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
        }
    }

    /// The outcome with its own symbol: a running turn in the key colour, a failure in red.
    private func outcome(_ summary: TurnSummary) -> some View {
        let reason: String
        if case .failed(let text) = summary.state, !text.isEmpty { reason = "\(summary.stateTitle): \(text)" }
        else { reason = summary.stateTitle }

        let (symbol, style): (String, AnyShapeStyle) = switch summary.state {
        case .running:    ("circle.dotted", AnyShapeStyle(.tint))
        case .completed:  ("checkmark.circle.fill", AnyShapeStyle(.green))
        case .stopped:    ("stop.circle.fill", AnyShapeStyle(.secondary))
        case .failed:     ("exclamationmark.triangle.fill", AnyShapeStyle(.red))
        case .unfinished: ("exclamationmark.triangle.fill", AnyShapeStyle(.orange))
        }

        return Label {
            Text(reason)
                .fixedSize(
                    horizontal: false,
                    vertical  : true
                )
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(style)
        }
    }
}
