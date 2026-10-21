//
//  HouseModelSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import ModelTransports
import SwiftUI

/// HouseModelSection is the worker's profile as it stands, as the app's `InspectorModelSection`
/// shows it, on `MockTeam`'s values: the provider, a row that opens in place into the list of
/// providers (`InspectorProviderRow`), its chevron turning with it; the model and effort, which
/// the composer changes; how the provider is reached; and its connection.
///
/// Choosing a provider applies it at once, after asking when the move is between local and cloud
/// or between a subscription and a metered key, and closes the list. The connection says nothing
/// more than its state while it works, and what to do when it does not. All Providers counts the
/// ready connections and lists every provider in a popover, standing in for the app's Providers
/// sheet.
struct HouseModelSection: View {
    let worker: MockWorker
    let team  : MockTeam

    /// Whether this worker's list of providers is open.
    @Binding var isChoosing: Bool

    /// The provider waiting on the person's consent, with the sentence they consent to.
    @State private var pending: (provider: ModelProvider, sentence: String)?

    @State private var showsProviders = false

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    var body: some View {
        let selection = team.selection(of: worker)

        Section {
            providerRow(selection.provider)

            if isChoosing {
                ForEach(ModelProvider.allCases) { provider in
                    InspectorProviderRow(
                        provider : provider,
                        isCurrent: provider == selection.provider,
                        state    : team.connectionStates[provider]
                    ) {
                        choose(provider)
                    }
                    // The list stands apart from the row that opened it, its rows a little taller.
                    .padding(
                        .top,
                        provider == ModelProvider.allCases.first ? 10 : 0
                    )
                    .padding(
                        .vertical,
                        3
                    )
                }
            }

            LabeledContent(
                "Model",
                value: selection.line
            )
            LabeledContent(
                "Access",
                value: Self.access(selection.provider)
            )
            LabeledContent("Connection") { connection(selection.provider) }
            allProviders
        } header: {
            Text("Model")
        } footer: {
            HouseSectionGap()
        }
        .confirmationDialog(
            "Change \(worker.name)’s Provider?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting : pending
        ) { choice in
            Button("Change Provider") { apply(choice.provider) }
            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: { choice in
            Text(choice.sentence)
        }
    }

    /// "Subscription · Claude Code", or the kind of access alone where the provider says the rest.
    static func access(_ provider: ModelProvider) -> String {
        let authentication = ProviderConnection(provider: provider).authentication
        guard authentication == .signedInCommandLine else { return authentication.title }

        return "\(authentication.title) · \(SignInFailure.name(of: provider))"
    }

    // MARK: Choosing

    /// The provider, a row that opens and closes the list, its chevron turning with it.
    private func providerRow(_ provider: ModelProvider) -> some View {
        Button { setChoosing(!isChoosing) } label: {
            LabeledContent("Provider") {
                HStack(
                    alignment: .firstTextBaseline,
                    spacing  : 6
                ) {
                    Text(provider.title)
                    DisclosureChevron(isOpen: isChoosing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isChoosing ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows the providers to choose from")
    }

    /// Opens or closes the list in one animation: its rows come in and out, the rows below move,
    /// and the chevron turns.
    private func setChoosing(_ isOpen: Bool) {
        withAnimation(reducesMotion ? nil : .snappy(duration: 0.25)) { isChoosing = isOpen }
    }

    /// Asks first when the move needs consent, and applies it otherwise.
    private func choose(_ provider: ModelProvider) {
        let current = team.selection(of: worker).provider
        guard provider != current else {
            setChoosing(false)
            return
        }

        if let sentence = ProviderConnection(provider: provider).consentNeeded(
            movingFrom: ProviderConnection(provider: current)
        ) {
            pending = (provider, sentence)
            return
        }
        apply(provider)
    }

    private func apply(_ provider: ModelProvider) {
        setChoosing(false)
        team.changeProvider(
            of: worker,
            to: provider
        )
    }

    // MARK: Connection

    /// The provider's last check: its state alone while it works, what to do when it does not.
    @ViewBuilder
    private func connection(_ provider: ModelProvider) -> some View {
        if let state = team.connectionStates[provider] {
            if state.isReady {
                Text(state.title)
            } else {
                VStack(
                    alignment: .trailing,
                    spacing  : 6
                ) {
                    StatusText(
                        state.message(for: provider),
                        tone: .trouble
                    )
                    Button("Providers…") { showsProviders = true }
                        .controlSize(.small)
                }
            }
        } else if team.checking.contains(provider) {
            StatusText(
                "Checking…",
                tone: .waiting
            )
            .shimmering()
        } else {
            HStack(spacing: 8) {
                StatusText(
                    "Not checked yet",
                    tone: .quiet
                )
                Button {
                    team.check(provider)
                } label: {
                    Label(
                        "Check",
                        systemImage: "arrow.clockwise"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Check connection.")
            }
        }
    }

    /// The ready connections counted, a row that lists every provider in a popover.
    private var allProviders: some View {
        Button { showsProviders = true } label: {
            LabeledContent("All Providers") {
                HStack(
                    alignment: .firstTextBaseline,
                    spacing  : 6
                ) {
                    Text("\(team.readyConnections) Ready")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows every provider and its connection")
        .popover(
            isPresented: $showsProviders,
            arrowEdge  : .leading
        ) {
            ProviderList(team: team)
        }
    }

    /// ProviderList is every provider, a row each, as the app's Providers sheet lists them: how it
    /// is reached as a symbol, its name and the kind of access, and its connection's state without
    /// words, which its help and VoiceOver say (`ConnectionStateBadge`).
    private struct ProviderList: View {
        let team: MockTeam

        var body: some View {
            VStack(
                alignment: .leading,
                spacing  : 0
            ) {
                Text("Providers")
                    .font(.headline)
                    .padding(
                        .bottom,
                        12
                    )
                ForEach(ModelProvider.allCases) { provider in
                    if provider != ModelProvider.allCases.first { Divider() }
                    row(provider)
                }
            }
            .padding(20)
            .frame(width: 300)
        }

        private func row(_ provider: ModelProvider) -> some View {
            let authentication = ProviderConnection(provider: provider).authentication
            return HStack(spacing: 10) {
                Image(systemName: Self.symbol(of: authentication))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(
                    alignment: .leading,
                    spacing  : 2
                ) {
                    Text(provider.title)
                    Text(authentication.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ConnectionStateBadge(
                    state     : team.connectionStates[provider],
                    isChecking: team.checking.contains(provider)
                )
            }
            .padding(
                .vertical,
                11
            )
            .accessibilityElement(children: .combine)
        }

        /// The symbol the app's Providers sheet gives each kind of access.
        private static func symbol(of authentication: ProviderConnection.Authentication) -> String {
            switch authentication {
            case .signedInCommandLine: "terminal"
            case .apiKey             : "cloud"
            case .localServer        : "server.rack"
            }
        }
    }
}
