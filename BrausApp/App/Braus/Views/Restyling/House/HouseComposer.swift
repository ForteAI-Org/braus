//
//  HouseComposer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseComposer is the mockup's composer: a 52 point glass pill holding, from leading to trailing,
/// the `+` menu, the message field, the model and effort menu, the context ring and Send.
///
/// The field takes the keyboard focus when the composer appears, which is when a worker is chosen,
/// so the sidebar's selection draws unemphasized. Return sends a message that is not blank, hands it
/// to `onSend` and clears the field. The `+` menu's items and the ring's actions are placeholders.
struct HouseComposer: View {
    let worker: MockWorker
    let onSend: (String) -> Void

    @State private var text = ""

    @State private var model = "Opus 5.5"

    @State private var effort = "High"

    @State private var showsChromeWindow = false

    @State private var showsContext = false

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            addMenu
            TextField(
                "Message \(worker.name)",
                text: $text
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isFieldFocused)
            // Return in the field sends too; a second call from Send's shortcut finds the field empty.
            .onSubmit(send)
            modelMenu
            ConversationContextButton(
                context        : Self.context,
                worker         : worker.name,
                isCompacting   : false,
                waitReason     : nil,
                compact        : {},
                startFresh     : {},
                isShowingDetail: $showsContext
            )
            .buttonStyle(.borderless)
            sendButton
        }
        .padding(
            .leading,
            10
        )
        .padding(
            .trailing,
            8
        )
        .frame(height: 52)
        .modifier(GlassCapsule())
        .shadow(
            color : .black.opacity(0.5),
            radius: 20,
            y     : 20
        )
        .task {
            // Asked for before the field is in its window, the focus is dropped and stays on the sidebar.
            await Task.yield()
            isFieldFocused = true
        }
    }

    /// The mock context: a third of a 200k window.
    private static let context = WorkerUsage.Context(
        tokens: 68_000,
        window: 200_000
    )

    private static let models  = ["Opus 5.5", "Haiku 4.5"]
    private static let efforts = ["Low", "Medium", "High"]

    private var addMenu: some View {
        Menu {
            Button("Attach File…") {}
            Button("Search the Web") {}
            Toggle(
                "Show Chrome Window",
                isOn: $showsChromeWindow
            )
        } label: {
            Image(systemName: "plus")
                .font(.system(
                    size  : 15,
                    weight: .medium
                ))
                .foregroundStyle(.secondary)
                .frame(
                    width : 30,
                    height: 30
                )
                .background(
                    .white.opacity(0.06),
                    in: Circle()
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach a file, search the web, or show the Chrome window.")
        .accessibilityLabel("Add")
    }

    private var modelMenu: some View {
        Menu {
            Picker(
                "Model",
                selection: $model
            ) {
                ForEach(
                    Self.models,
                    id: \.self
                ) { Text($0) }
            }
            .pickerStyle(.inline)
            Picker(
                "Effort",
                selection: $effort
            ) {
                ForEach(
                    Self.efforts,
                    id: \.self
                ) { Text($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text("\(model) · \(effort)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(
                    .horizontal,
                    10
                )
                .padding(
                    .vertical,
                    5
                )
                .background(
                    .white.opacity(0.06),
                    in: Capsule()
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the model and its effort.")
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(
                    size  : 15,
                    weight: .semibold
                ))
                .foregroundStyle(.black)
                .frame(
                    width : 36,
                    height: 36
                )
                .background(
                    LinearGradient(
                        colors    : [Color(white: 0.96), Color(white: 0.72)],
                        startPoint: UnitPoint(x: 0.33, y: 0),
                        endPoint  : UnitPoint(x: 0.67, y: 1)
                    ),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return)
        .disabled(message.isEmpty)
        .help("Send")
        .accessibilityLabel("Send")
    }

    private var message: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !message.isEmpty else { return }

        onSend(message)
        text = ""
    }
}
