//
//  HouseNewWorkerSheet.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import ModelTransports
import SwiftUI

/// HouseNewWorkerSheet is the app's New Worker sheet (`NewWorkerSheet`) in the house's language: the
/// same title, grouped list and bar with Cancel and Create, the default button, with the worker's
/// shape chosen where the app shows its colour and a new random shape.
///
/// The first group is the eight shapes as live mascots (`HouseShapeGrid`), one already chosen: a
/// shape no worker has yet when there is one. The second is the name, the only field required and
/// the one with the keyboard when the sheet opens, the role, which the room shows under the name
/// while the worker is free, and the instructions. The third is the provider, each with its
/// connection's state, and the model: the first ready provider and the model it comes with are
/// chosen already, so a name and Return make a worker.
///
/// The sheet owns no data: `connections` tells each provider's state, `catalogue` lists a
/// provider's models, and `create` makes the worker from what was chosen, whose room then fades in
/// (`HouseLayout.arrival`). The mockup passes fixed ones, the live house the team's own. `house`
/// only suggests the first shape.
struct HouseNewWorkerSheet: View {

    /// What Create hands over: the details as typed (trimmed, empty ones nil) and the chosen shape and
    /// model, nil when no model could be chosen.
    struct Request {
        let name        : String
        let role        : String?
        let instructions: String?
        let shape       : WorkerShape
        let selection   : ModelSelection?
    }

    let house      : MockHouse
    let connections: () -> [ModelProvider: ConnectionState]
    let catalogue  : (ModelProvider) async -> [ModelInfo]
    let create     : (Request) -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var name         = ""
    @State private var role         = ""
    @State private var instructions = ""
    @State private var provider     : ModelProvider?
    @State private var shape        : WorkerShape

    /// The chosen provider's models, nil while they are being listed.
    @State private var models: [ModelInfo]?
    @State private var model : String?

    @FocusState private var namesFirst: Bool

    init(
        house      : MockHouse,
        connections: @escaping () -> [ModelProvider: ConnectionState],
        catalogue  : @escaping (ModelProvider) async -> [ModelInfo],
        create     : @escaping (Request) -> Void
    ) {
        self.house       = house
        self.connections = connections
        self.catalogue   = catalogue
        self.create      = create
        _provider        = State(initialValue: .preselected(in: connections()))
        _shape           = State(initialValue: house.suggestedShape(seed: .random(in: 0...UInt64.max)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Worker")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .frame(
                    maxWidth : .infinity,
                    alignment: .leading
                )
                .padding(
                    .horizontal,
                    20
                )
                .padding(
                    .top,
                    20
                )

            Form {
                Section {
                    HouseShapeGrid(selection: $shape)
                        .frame(maxWidth: .infinity)
                        .padding(
                            .vertical,
                            4
                        )
                }

                Section {
                    TextField(
                        "Name",
                        text  : $name,
                        prompt: Text("Worker name")
                    )
                    .focused($namesFirst)

                    TextField(
                        "Role",
                        text  : $role,
                        prompt: Text("Example: Researcher")
                    )

                    TextField(
                        "Instructions",
                        text  : $instructions,
                        prompt: Text("Describe responsibilities or constraints"),
                        axis  : .vertical
                    )
                    .lineLimit(2...5)
                }

                Section {
                    Picker(
                        "Provider",
                        selection: $provider
                    ) {
                        Text("Choose Later").tag(ModelProvider?.none)

                        Divider()

                        ForEach(ModelProvider.allCases) { provider in
                            Text(label(of: provider)).tag(Optional(provider))
                        }
                    }

                    modelRow
                } footer: {
                    Text("You can change the model later from the composer. Braus asks for permission only when this worker first uses your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)

            Divider()

            HStack {
                Spacer()

                Button(
                    "Cancel",
                    role: .cancel
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") { createWorker() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(
                .horizontal,
                20
            )
            .padding(
                .vertical,
                14
            )
        }
        .frame(
            width : 460,
            height: 570
        )
        .onAppear { namesFirst = true }
        .task(id: provider) { await listModels() }
    }

    // MARK: Parts

    /// The chosen provider's models, or a few quiet words when there are none to choose.
    @ViewBuilder
    private var modelRow: some View {
        if provider != nil, let models, !models.isEmpty {
            Picker(
                "Model",
                selection: $model
            ) {
                ForEach(models) { entry in
                    Text(entry.title).tag(Optional(entry.id))
                }
            }
        } else {
            LabeledContent("Model") {
                if let provider, models == nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading \(provider.title) models")
                } else if let provider {
                    Text(unavailable(provider))
                        .foregroundStyle(.secondary)
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The provider's name and its connection's state, in the inspector's words.
    private func label(of provider: ModelProvider) -> String {
        "\(provider.title) · \(connections()[provider]?.title ?? "Not checked yet")"
    }

    /// Why a provider lists no model, as the app says it: what to do about a missing command line,
    /// else its connection's state.
    private func unavailable(_ provider: ModelProvider) -> String {
        guard let state = connections()[provider], !state.isReady else { return "No models available" }

        return state == .notInstalled ? "Install \(provider.title), then sign in." : state.title
    }

    /// Lists the chosen provider's models and picks the one it comes with.
    private func listModels() async {
        models = nil
        model  = nil
        guard let provider else { return }

        let listed = await catalogue(provider)
        // Another provider was chosen meanwhile, and its own listing replaces this one.
        guard !Task.isCancelled else { return }

        models = listed
        model  = provider.startingModel(in: listed)?.id
    }

    /// The provider and model chosen, at the model's starting effort; nil leaves the worker to configure.
    private var chosenSelection: ModelSelection? {
        guard let provider, let entry = models?.first(where: { $0.id == model }) else { return nil }

        return ModelSelection(
            provider: provider,
            model   : entry.id,
            effort  : entry.startingEffort
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createWorker() {
        let name         = trimmedName
        let role         = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        dismiss()
        create(Request(
            name        : name,
            role        : role.isEmpty ? nil : role,
            instructions: instructions.isEmpty ? nil : instructions,
            shape       : shape,
            selection   : chosenSelection
        ))
    }
}
