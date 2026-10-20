//
//  HouseInspector.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseInspector is the mockup's inspector, a grouped form as the app's own inspector is
/// (`WorkerInspectorView`): the worker's screen while it is busy and the toolbar's Screen toggle is
/// on, and its provider. With no worker chosen it says where the details come from.
///
/// The connection shows a symbol only when it has trouble. All Providers is a placeholder until
/// provider management is part of the mockup.
struct HouseInspector: View {
    let worker     : MockWorker?
    let showsScreen: Bool

    /// Whether the worker's connection has trouble, the only time the Connection row shows a symbol.
    var hasConnectionTrouble = false

    var body: some View {
        if let worker {
            Form {
                if showsScreen, worker.status == .busy {
                    Section("Screen") {
                        LabeledContent(
                            "App",
                            value: HouseMockScreen.appName(of: worker)
                        )
                        HouseMockScreen(worker: worker)
                    }
                }
                Section("Provider") {
                    LabeledContent(
                        "Provider",
                        value: "Anthropic"
                    )
                    LabeledContent(
                        "Access",
                        value: "Subscription · Claude Code"
                    )
                    LabeledContent("Connection") { connection }
                    Button {} label: {
                        LabeledContent("All Providers") {
                            HStack(spacing: 6) {
                                Text("3 Ready")
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Worker",
                systemImage: "info.circle",
                description: Text("Details appear when you choose a room.")
            )
        }
    }

    @ViewBuilder
    private var connection: some View {
        if hasConnectionTrouble {
            Label {
                Text("Not Responding")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Connected")
        }
    }
}
