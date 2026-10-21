//
//  ConversationComposer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SwiftUI

/// The composer (§13), floating over the transcript's bottom edge. Its field
/// hands the draft committed text only, never a composition in progress, so
/// the pause below writes finished text.
///
/// A reply in progress shows as a strip over the pill (`QuoteStrip`), with the
/// quoted message: a click on its text goes to that message, and its × or
/// Escape in the field drops the quote. The next send carries it.
///
/// A message sent while the worker answers joins the conversation's queue,
/// which shows as a strip above the reply's (`QueueStrip`): the reply strip
/// stays next to the pill, since it belongs to what is typed.
///
/// A draft that starts with `/` opens the command popup above the pill, at its
/// leading edge (`SlashCommandPopup`). The keyboard stays in the field, which
/// hands the popup ↑ ↓, Tab, Return and Escape while it is open; a first
/// Escape closes it, and the next one drops a quote as it always does.
///
/// The bar stands on the conversation's ground (`composerDock()`), and its `+`
/// menu shows or hides Braus's Chrome window for a conversation that browses,
/// as the inspector's Web section does. With `flights` a sent message, a
/// queued one and a quote fly across the conversation.
struct ConversationComposer: View {

    @Bindable
    var team: TeamModel

    let worker: WorkerSnapshot

    /// The composer's height, strip included, which the transcript keeps clear below its last message.
    @Binding var height: CGFloat

    /// A count that puts the keyboard in the field each time it moves.
    var focusRequest = 0

    /// Moves when a queued message comes back into the draft, to be edited at once.
    @State private var editFocus = 0

    /// Shows a message in the transcript, as a click on the reply strip asks.
    var reveal: (UUID) -> Void = { _ in }

    /// The conversation's flights (`HouseLiveFlights`); nil flies nothing.
    var flights: HouseLiveFlights?

    /// The model and effort chosen in the popup and not kept yet, nil while they are the worker's.
    @State private var pending: ModelSelection?

    @State private var isChoosingModel = WindowSnapshots.opensModelPopup

    private var sendsWithCommandReturn: Bool { AppPreferenceValues.shared.chatSendsWithCommandReturn }

    /// The model button's frame in the window, which the popup is centred on.
    @State private var modelButton = CGRect.zero

    /// The command popup's selection, and the draft it was closed on.
    @State private var commands = SlashCommandMenu()

    var body: some View {
        bar
        .sendsOnReturn(!sendsWithCommandReturn)
        .queuesWhileAnswering(true)
        .onEscape(team.draftQuote == nil ? nil : { dropQuote() })
        .popupKeys { key in
            commands.handle(
                key,
                in: team
            )
        }
        .focusRequest(focusRequest + editFocus)
        .strip { strips }
        .accessory {
            HStack(spacing: 2) {

                if let configuration = worker.configuration {
                    ConversationModelButton(
                        selection: pending ?? configuration,
                        catalogue: team.connections.catalogues[configuration.provider],
                        isOpen   : $isChoosingModel,
                        frame    : $modelButton,
                        isEnabled: !team.isAnswering(worker.id)
                    )
                }
            }
        }
        .modelPopup(
            isPresented: $isChoosingModel,
            button     : modelButton,
            selection  : Binding(
                get: { pending ?? worker.configuration ?? .default },
                set: { pending = $0 }
            ),
            catalogue  : worker.configuration.flatMap { team.connections.catalogues[$0.provider] },
            unavailable: worker.configuration.flatMap { team.connections.modelsUnavailable(for: $0.provider) },
            onClose    : { Task { await keepChoice() } }
        )
        .composerPopup(
            isPresented   : Binding(
                get: { !commands.rows(of: team).isEmpty },
                set: { if !$0 { commands.close(on: team.draft) } }
            ),
            placement     : .leading,
            width         : SlashCommandPopup.width,
            closesOnEscape: false
        ) {
            let rows = commands.rows(of: team)
            SlashCommandPopup(
                rows    : rows,
                selected: commands.selected(in: rows)?.id,
                select  : { row in
                    commands.select(
                        row,
                        in: rows
                    )
                },
                choose  : { row in
                    commands.choose(
                        row,
                        in: team
                    )
                }
            )
        }
        // What `/observe` read of the worker's window, with the elements the agent sees.
        .popover(
            isPresented: Binding(
                get: { team.observation != nil },
                set: { if !$0 { team.observation = nil } }
            ),
            arrowEdge  : .top
        ) {
            if let observation = team.observation {
                ConversationObservedScreen(
                    scene: observation.scene,
                    image: observation.image
                )
            }
        }
        .animation(
            ComposerBar.stripAnimation,
            value: team.draftQuote
        )
        .animation(
            ComposerBar.stripAnimation,
            value: team.queue
        )
        .composerDock()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onChange(of: worker.id) {
            isChoosingModel = false
            pending         = nil
        }
        // `/model` alone opens the popup, as the model button does.
        .onChange(of: team.modelPopupRequest) { isChoosingModel = true }
        // The model popup takes the command popup's place; a new draft opens the command popup again.
        .onChange(of: isChoosingModel) {
            if isChoosingModel { commands.close(on: team.draft) }
        }
        .onChange(of: team.draft) { commands.draftChanged(to: team.draft) }
        // The draft reaches the store once typing pauses. A new keystroke
        // cancels this task and starts it again, so a burst writes once.
        .task(id: team.draft) {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await team.flushDraft()
        }
        // A quote comes and goes in one act, not in keystrokes, so it is written at once.
        .task(id: team.draftQuote) { await team.flushDraft() }
    }

    /// The bar, with its `+` menu while the conversation browses.
    private var bar: ComposerBar {
        let bar = ComposerBar(
            draft      : $team.draft,
            recipient  : worker.name,
            canAnswer  : canAnswer,
            isAnswering: team.isAnswering(worker.id),
            send       : {
                depart()
                Task { await keepChoice(); await team.send() }
            },
            stop       : { team.stopAnswering(worker.id) },
            release    : team.holdsComputer(worker.id) ? { Task { await team.releaseComputer(worker.id) } } : nil
        )
        .fieldLink(flights?.field)
        guard team.composesWeb,
              let conversation = team.conversation,
              conversation.participantIDs.contains(worker.id)
        else { return bar }

        let id       = conversation.id
        let personal = team.usesPersonalChrome(in: id)
        let profile  = team.chromeProfile(in: id)
        return bar.menu {
            Toggle(
                "Show Chrome Window",
                isOn: Binding(
                    get: { team.showsBrowserWindow(in: id) },
                    set: { shows in Task { await team.setShowsBrowserWindow(shows, in: id) } }
                )
            )
            // Braus's Chrome has no window to show while the person's own or a paired one is used.
            .disabled(personal || profile != nil)
        }
    }

    /// The strips, tabs over the pill: the queue's, which pages, sends now, removes and takes a
    /// message back to edit, and the reply's, whose line goes to the quoted message. Their lines are
    /// where the flights land and leave.
    private var strips: some View {
        VStack(spacing: 0) {
            if !team.queue.isEmpty {
                QueueStrip(
                    items      : team.queue.map(\.excerpt),
                    page       : team.shownQueuedIndex,
                    hidesText  : flights?.hidesQueueLine ?? false,
                    onTextFrame: { flights?.queueLine = $0 },
                    onPage     : { page in
                        // The team pages forward only, round the ends.
                        for _ in team.queue.indices where team.shownQueuedIndex != page { team.showNextQueued() }
                    },
                    onSendNow  : { Task { await team.sendQueuedNow() } },
                    onDrop     : {
                        flights?.expectRemoval()
                        Task { await team.removeShownQueued() }
                    },
                    onEdit     : {
                        flights?.expectRemoval()
                        editFocus += 1
                        Task { await team.editShownQueued() }
                    }
                )
                .transition(.opacity)
            }
            if let quote = team.draftQuote {
                QuoteStrip(
                    title      : quote.isFromPerson ? "Reply" : "Reply to \(worker.name)",
                    text       : quote.excerpt,
                    hidesText  : flights?.hidesQuoteLine ?? false,
                    onTextFrame: { flights?.quoteLine = $0 },
                    onRemove   : dropQuote,
                    onOpen     : { reveal(quote.messageID) }
                )
                .transition(.opacity)
            }
        }
    }

    /// The draft about to be sent sets off its flight from the field: into the
    /// transcript, or into the queue strip during a turn. A command flies nowhere.
    private func depart() {
        let text = team.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let flights, !text.isEmpty, SlashCommandInvocation(draft: text) == nil else { return }

        flights.depart(
            queued    : team.isAnswering(worker.id),
            leadsQueue: team.queue.isEmpty
        )
    }

    /// Takes the quote off the draft; with flights its line flies back into its bubble.
    private func dropQuote() {
        if let flights {
            flights.unquote(in: team)
        } else {
            team.draftQuote = nil
        }
    }

    /// Makes the popup's choice the worker's, a new version of its profile, when it changed anything.
    private func keepChoice() async {
        guard let choice = pending else { return }

        pending = nil
        guard choice != worker.configuration else { return }

        await team.configure(
            worker.id,
            selection: choice
        )
    }

    /// Whether this worker can answer: it has a model the catalogue still
    /// offers. The inspector shows which of these is missing; the composer
    /// only says to choose a model.
    private var canAnswer: Bool {
        guard worker.configuration != nil else { return false }
        if case .modelRemoved = team.modelStates[worker.id] { return false }

        return true
    }
}
