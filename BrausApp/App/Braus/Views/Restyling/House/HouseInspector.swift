//
//  HouseInspector.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseInspector is the mockup's inspector, a grouped form as the app's own inspector is
/// (`WorkerInspectorView`): the worker itself, which the person edits here (`WorkerSection`), the
/// worker's screen while it is busy and the toolbar's Screen toggle is on, and its provider. With no
/// worker chosen it says where the details come from.
///
/// The connection shows a symbol only when it has trouble. All Providers is a placeholder until
/// provider management is part of the mockup.
struct HouseInspector: View {
    let worker     : Binding<MockWorker>?
    let showsScreen: Bool

    /// Whether the worker's connection has trouble, the only time the Connection row shows a symbol.
    var hasConnectionTrouble = false

    var body: some View {
        if let binding = worker {
            let worker = binding.wrappedValue
            Form {
                WorkerSection(worker: binding)
                    .id(worker.id)
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

    /// WorkerSection is the worker as the person made it: its name, its role and its shape, which
    /// opens the New Worker sheet's shape grid in a popover. A new shape re-renders the worker's room
    /// and its mascot at the top of the conversation.
    ///
    /// The role follows every keystroke, as the room shows it. The name is taken on Return or when
    /// the field loses the keyboard, and a name emptied there comes back: a worker always has one.
    private struct WorkerSection: View {
        @Binding var worker: MockWorker

        @State private var name: String

        @State private var isChoosingShape = false

        @FocusState private var isNameFocused: Bool

        init(worker: Binding<MockWorker>) {
            _worker = worker
            _name   = State(initialValue: worker.wrappedValue.name)
        }

        var body: some View {
            Section("Worker") {
                TextField(
                    "Name",
                    text  : $name,
                    prompt: Text("Worker name")
                )
                .focused($isNameFocused)
                .onSubmit(takeName)

                TextField(
                    "Role",
                    text  : $worker.role,
                    prompt: Text("Example: Researcher")
                )

                Button { isChoosingShape = true } label: {
                    LabeledContent("Shape") {
                        HStack(spacing: 6) {
                            // In an overlay the mascot gives the row no baseline of its own, so the
                            // shape's name lines up with the label.
                            Color.clear
                                .frame(
                                    width : 28,
                                    height: 18
                                )
                                .overlay {
                                    MascotFace(
                                        shape : worker.shape,
                                        status: .free,
                                        brows : .idle,
                                        size  : 18
                                    )
                                }
                            Text(worker.shape.name)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Shape")
                .accessibilityValue(worker.shape.name)
                .accessibilityHint("Shows the shapes to choose from")
                .accessibilityAddTraits(.isButton)
                .popover(
                    isPresented: $isChoosingShape,
                    arrowEdge  : .leading
                ) {
                    HouseShapeGrid(selection: $worker.shape)
                        .padding(12)
                }
            }
            .onChange(of: isNameFocused) {
                if !isNameFocused { takeName() }
            }
        }

        private func takeName() {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { worker.name = trimmed }
            name = worker.name
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
