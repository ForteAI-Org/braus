//
//  HouseInspector.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseInspector is the mockup's inspector, a grouped form as the app's own inspector is
/// (`WorkerInspectorView`), with its sections on `MockTeam`'s values: the worker itself, which the
/// person edits here (`WorkerSection`), where the worker is now, its screen while it is busy and the
/// toolbar's Screen toggle is on, its model and provider, its Chrome window, and its current or last
/// turn (`InspectorTurnSection`). With no worker chosen it says where the details come from.
///
/// Every section but the worker's folds under its title, and the list of providers opens in place; the inspector
/// keeps both per worker (`InspectorDisclosure`), so coming back to a worker finds its inspector
/// as it was left.
struct HouseInspector: View {
    let worker     : Binding<MockWorker>?
    let showsScreen: Bool

    @State private var disclosure = InspectorDisclosure()

    @Environment(MockTeam.self)
    private var team: MockTeam?

    var body: some View {
        if let binding = worker, let team {
            let worker = binding.wrappedValue
            Form {
                ForEach(Self.parts(
                    showsScreen: showsScreen,
                    isBusy     : worker.status == .busy
                )) { part in
                    section(
                        part,
                        binding: binding,
                        team   : team
                    )
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

    /// Part is one section of the inspector, in the order they stand.
    enum Part: Identifiable, CaseIterable {
        case screen, worker, now, model, web, turn

        var id: Self { self }
    }

    /// The sections that stand now, in order: Screen comes first whenever the worker is busy and
    /// the toolbar's Screen toggle is on, then the worker itself.
    static func parts(
        showsScreen: Bool,
        isBusy     : Bool
    ) -> [Part] {
        Part.allCases.filter { $0 != .screen || (showsScreen && isBusy) }
    }

    @ViewBuilder
    private func section(
        _ part  : Part,
        binding : Binding<MockWorker>,
        team    : MockTeam
    ) -> some View {
        let worker = binding.wrappedValue
        switch part {
        case .screen:
            HouseScreenSection(
                worker    : worker,
                isExpanded: expansion(
                    .screen,
                    of: worker
                )
            )
        case .worker:
            WorkerSection(worker: binding)
                .id(worker.id)
        case .now:
            HouseNowSection(
                worker    : worker,
                team      : team,
                isExpanded: expansion(
                    .now,
                    of: worker
                )
            )
        case .model:
            HouseModelSection(
                worker    : worker,
                team      : team,
                isExpanded: expansion(
                    .model,
                    of: worker
                ),
                isChoosing: Binding(
                    get: { disclosure.choosingProviderFor == worker.id },
                    set: { disclosure.choosingProviderFor = $0 ? worker.id : nil }
                )
            )
        case .web:
            HouseWebSection(
                worker    : worker,
                team      : team,
                isExpanded: expansion(
                    .web,
                    of: worker
                )
            )
        case .turn:
            InspectorTurnSection(
                workerName: worker.name,
                turn      : team.lastTurn(of: worker),
                isExpanded: expansion(
                    .turn,
                    of: worker
                )
            )
        }
    }

    /// Whether `section` is open for `worker`, which folding it changes for that worker alone.
    private func expansion(
        _ section: InspectorDisclosure.Section,
        of worker: MockWorker
    ) -> Binding<Bool> {
        Binding(
            get: {
                disclosure.isExpanded(
                    section,
                    for: worker.id
                )
            },
            set: { isExpanded in
                disclosure.setExpanded(
                    isExpanded,
                    section,
                    for: worker.id
                )
            }
        )
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
                                    HouseWorkerPortrait(
                                        shape : worker.shape,
                                        status: .free,
                                        size  : 18,
                                        brows : .idle
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
}
