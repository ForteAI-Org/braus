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
/// The connections and the models are the mockup's, fixed; nothing is checked or listed. Create
/// adds the worker to `house` with its name, role and shape, whose room fades in
/// (`HouseLayout.arrival`), and hands its id to `created`. The house keeps no instructions or
/// provider yet, so those go no further.
struct HouseNewWorkerSheet: View {
    @Binding var house: MockHouse

    let created: (MockWorker.ID) -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var name         = ""
    @State private var role         = ""
    @State private var instructions = ""
    @State private var provider     = ModelProvider.preselected(in: Self.connections)
    @State private var shape: WorkerShape
    @State private var model: String?

    @FocusState private var namesFirst: Bool

    /// The mockup's connections, as its inspector tells them: three ready, one to set up, one missing.
    private static let connections: [ModelProvider: ConnectionState] = [
        .codex     : .ready,
        .claudeCode: .ready,
        .anthropic : .ready,
        .gemini    : .credentialMissing,
        .ollama    : .notInstalled,
    ]

    init(
        house  : Binding<MockHouse>,
        created: @escaping (MockWorker.ID) -> Void
    ) {
        _house       = house
        self.created = created
        _shape       = State(initialValue: house.wrappedValue.suggestedShape(seed: .random(in: 0...UInt64.max)))
        _model       = State(initialValue: Self.models(of: .preselected(in: Self.connections)).first)
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
                            Text(Self.label(of: provider)).tag(Optional(provider))
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

                Button("Create") { create() }
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
        .onChange(of: provider) { model = Self.models(of: provider).first }
    }

    // MARK: Parts

    /// The chosen provider's models, or a few quiet words when there are none to choose.
    @ViewBuilder
    private var modelRow: some View {
        let models = Self.models(of: provider)
        if !models.isEmpty {
            Picker(
                "Model",
                selection: $model
            ) {
                ForEach(
                    models,
                    id: \.self
                ) { id in
                    Text(ModelInfo.displayName(for: id)).tag(Optional(id))
                }
            }
        } else {
            LabeledContent("Model") {
                Text(provider.map(Self.unavailable) ?? "None")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A ready provider's models, the one it comes with first; none for a provider that is not ready.
    private static func models(of provider: ModelProvider?) -> [String] {
        guard let provider, connections[provider]?.isReady == true else { return [] }
        return provider.defaultModels
    }

    /// The provider's name and its connection's state, in the inspector's words.
    private static func label(of provider: ModelProvider) -> String {
        "\(provider.title) · \(connections[provider]?.title ?? "Not checked yet")"
    }

    /// Why a provider lists no model, as the app says it: what to do about a missing command line,
    /// else its connection's state.
    private static func unavailable(_ provider: ModelProvider) -> String {
        guard let state = connections[provider], !state.isReady else { return "No models available" }

        return state == .notInstalled ? "Install \(provider.title), then sign in." : state.title
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        let name = trimmedName
        guard !name.isEmpty else { return }

        dismiss()
        created(house.add(
            name : name,
            role : role.trimmingCharacters(in: .whitespacesAndNewlines),
            shape: shape
        ))
    }
}
