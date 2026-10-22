//
//  TeamModel.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import AppKit
import AutomationMCP
import AutomationRuntime
import ChatCore
import ChromeProfiles
import Foundation
import MacSession
import Memory
import ModelTransports
import Observation
import PerceptionCore
import Router
import os
import SeatBroker
import WebSession

/// A problem in the language an alert needs: a specific title, an actionable
/// explanation, and optional diagnostic detail kept out of the main message.
nonisolated struct UserFacingIssue: Sendable, Equatable {
    let title           : String
    let message         : String
    let technicalDetails: String?

    init(
        title           : String,
        message         : String,
        technicalDetails: String? = nil
    ) {
        self.title            = title
        self.message          = message
        self.technicalDetails = technicalDetails
    }

    var displayMessage: String {
        guard let technicalDetails, !technicalDetails.isEmpty else { return message }
        return "\(message)\n\nDetails: \(technicalDetails)"
    }
}

/// TeamModel is the only thing in the app that talks to `WorkspaceStore`.
///
/// The store is an actor holding a SwiftData context; every call here awaits
/// it and keeps the snapshots it hands back. Views read this object and never
/// the store, so no view holds a model row and no row crosses an isolation
/// boundary.
///
/// A worker on Claude Code or Codex answers through its agent command line with
/// Braus's tools (`WorkerAgents`), and a worker on a model provider through
/// Braus's own loop with the same tools. Those tools reach the desktop only
/// through the broker's queue (`BrokeredAutomationSession`, §22.3): a worker
/// waits for the computer like any other entry and never builds a seat.
///
/// Connections come from `connections`, the same store the Settings window
/// edits, so a key entered in either place serves both.
///
/// A worker's context is compacted as a turn of its own, when the person asks
/// or after a completed turn leaves it at 90% or more, and started again when
/// the person asks (`compactContext`, `startFreshContext`).
///
/// A message sent while its worker answers joins its conversation's queue and
/// goes out, one at a time, as turns end (`send`, `sendShownQueued`).
///
/// A refusal from the store becomes `problem`, a sentence naming what was
/// refused and what to do about it. Nothing here fails silently.
@Observable
@MainActor
final class TeamModel {

    let store: WorkspaceStore

    let connections: ModelSettingsStore

    /// The active team and the archive, as the store last answered.
    private(set) var active  : [WorkerSnapshot] = []
    private(set) var archived: [WorkerSnapshot] = []

    var selection       : UUID?
    var isCreatingWorker = false

    /// The connection cards, reachable from the team (§19.1).
    var isShowingConnections = false

    /// True while the Mac Access sheet is up: the macOS permissions a worker's seat needs.
    var isShowingPermissions = false

    /// The worker whose list of providers is open in the inspector, if any. The worker's
    /// commands set it to open the inspector on that list.
    var choosingProviderFor: UUID?

    /// The worker whose name the person asked to edit. The window shows the inspector for it, and
    /// its Worker section puts the keyboard in the Name field and clears this.
    var editingWorker: UUID?

    /// Chooses `id` and asks for its Name field to take the keyboard, which the inspector's Worker section answers.
    func editWorker(_ id: UUID) {
        selection     = id
        editingWorker = id
    }

    /// The worker the person asked to delete, whose confirmation the team window shows.
    var deletingWorker: UUID?

    /// The toolbar's token popover and the context ring's popover are open, as
    /// their buttons and `/usage` and `/context` open them. Both close when
    /// another conversation opens.
    var showsUsage   = false
    var showsContext = false

    /// The worker's window as `/observe` read it, the scene and its pixels,
    /// shown in the composer's popover until it closes; nil while none is
    /// shown. It closes when another conversation opens.
    var observation: (scene: SceneSnapshot, image: CGImage)?

    /// Moves each time `/model` asks the composer to open its model popup.
    var modelPopupRequest = 0

    /// What the last check said about each configured worker's model. A
    /// worker absent here has not been checked, which is not the same as fine.
    private(set) var modelStates: [UUID: ConnectionState] = [:]

    /// What each worker's direct conversation holds unseen, as the store last
    /// derived it from its read markers. A worker absent here has nothing.
    private(set) var unread: [UUID: UnreadState] = [:]

    /// What each worker's turns used and how full its context is, as the store
    /// last summed it: read when its conversation opens, its model changes or
    /// a turn ends. A worker absent here has not been read yet.
    private(set) var usage: [UUID: WorkerUsage] = [:]

    /// What the store refused, ready for a specific alert. Nil while nothing is pending.
    var problem: UserFacingIssue?

    private(set) var conversation: ConversationSnapshot?

    /// Moves each time the store records something for the open conversation.
    /// The transcript reads its own windows through `transcriptSource` and
    /// refreshes on a change; nothing here holds the history.
    private(set) var transcriptRevision = 0

    /// The read-only seam the transcript loads windows through (§12.5).
    /// Writes still go through this model only.
    var transcriptSource: any ConversationWindowSource { store }

    /// Workers whose turn is running, each with the conversation it runs in.
    /// One turn at a time per worker; the others are unaffected.
    private(set) var answering: [UUID: UUID] = [:]

    /// Workers whose context is being compacted. Each is in `answering` too, so
    /// the composer waits as it does behind a turn, and Stop ends the compaction.
    private(set) var compacting: Set<UUID> = []

    /// Stops asked for before the worker's agent had started.
    private var pendingStops: Set<UUID> = []

    /// The messages sent while each conversation's worker answered, in order,
    /// by conversation: what the store holds, read when the conversation first
    /// opens in this process and written on every change.
    private var queues: [UUID: [QueuedMessage]] = [:]

    /// The queued message each conversation's strip shows, which is the one
    /// that goes next. Absent means the first; it is not stored, so a relaunch
    /// shows the first.
    private var shownQueued: [UUID: Int] = [:]

    /// Workers whose turn Send Now stopped, so the shown queued message goes
    /// out as soon as the turn has ended, however it ended.
    private var sendsQueuedOnEnd: Set<UUID> = []

    /// One agent host per conversation, kept for the process so its turns share
    /// its tools and its router (each command line turn gets a loopback host of
    /// its own, `WorkerAgentHost`), with the desktop its tools were composed over:
    /// its worker's one desktop (`desktop(for:)`), so a conversation's host never
    /// runs over another desktop. The provider session lives on the conversation.
    private var hosts: [UUID: (host: WorkerAgentHost, desktop: BrokeredAutomationSession)] = [:]

    /// The conversation each worker last started a turn or a compaction in, the one context it acts in (I02).
    private var activeContexts: [UUID: UUID] = [:]

    /// The command line that answers for a provider, and the bridge it launches for Braus's tools.
    private let agents          : (ModelProvider) throws -> (ChatProvider, URL)
    private let bridgeExecutable: URL

    /// Where a turn reads the app's preferences as it starts (`AppPreferences`).
    private let preferences: UserDefaults

    /// The routes beyond the Seat each worker's session composes (`AppModel.session`); none keeps every
    /// app on the Seat and starts no Chrome.
    private let channels: AutomationChannels

    /// Whether the workers reach web pages in Braus's Chrome, so the Inspector offers its window.
    var composesWeb: Bool { channels.contains(.web) }

    /// The irreversible adapter calls waiting for the person's answer, which the window shows; nil refuses them.
    let approvals: AdapterApprovals?

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "Context"
    )

    /// The broker every worker's desktop goes through, the app's one. The Mac Access sheet asks it
    /// for the permissions.
    let broker: SeatBroker

    /// Each worker's desktop session, which its row reads while it waits for
    /// or holds the computer (§4.2).
    private var desktops: [UUID: BrokeredAutomationSession] = [:]

    /// Each conversation's web session, a Chrome tab its worker's tools reach with `web:<host>` or a URL,
    /// with the worker it belongs to. It takes no seat.
    private var webs: [UUID: (workerID: UUID, session: WebAutomationSession)] = [:]

    /// The conversations that show Braus's Chrome as a window instead of headless, kept across launches.
    private(set) var browserWindows = Set(
        (UserDefaults.standard.stringArray(forKey: AppPreferences.showsBrowserWindow) ?? []).compactMap(UUID.init)
    )

    /// The conversations that open their pages in the person's own Chrome instead of Braus's, kept across launches.
    private(set) var personalChromes = Set(
        (UserDefaults.standard.stringArray(forKey: AppPreferences.usesPersonalChrome) ?? []).compactMap(UUID.init)
    )

    /// The person's Chrome profiles paired with the Braus extension, the app's one hub; nil offers none.
    private let chromeProfileHub: ChromeProfileHub?

    /// The paired Chrome profiles as the hub last reported them, each connected or not: what the Inspector offers.
    private(set) var pairedChromeProfiles: [ChromeProfile] = []

    /// The paired Chrome profile each conversation opens its pages in, as the person chose it, kept across launches
    /// (`AppPreferences.chromeProfiles`). None by default: the conversation keeps Braus's Chrome, or the person's
    /// with Use My Chrome.
    private(set) var chromeProfileChoices: [UUID: ChromeProfileChoice] = TeamModel.storedChromeProfiles()

    /// Increment 1 has one workspace per store, and the schema gives it no row
    /// yet, so its events carry this fixed id.
    private static let workspaceID = UUID(uuid: (0x4d, 0x45, 0x43, 0x55, 0x4d, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))

    /// The draft as typed. It reaches the store on a pause and when the
    /// conversation changes, not on every keystroke; `savedDraft` is what the
    /// store holds, so an unchanged draft writes nothing.
    var draft: String = ""

    private var savedDraft: String = ""

    /// The message the draft replies to, persisted with the draft and by the
    /// same flush; `savedDraftQuote` is what the store holds. The next send
    /// carries it, and the agent receives it above the message (`agentText`).
    var draftQuote: MessageQuote?

    private var savedDraftQuote: MessageQuote?

    /// Counts calls to `openSelectedConversation`. A call that sees a newer
    /// number after a suspension was overtaken and writes nothing.
    private var openingGeneration = 0

    /// A send is between capturing the draft and the store's answer. A second
    /// send in that window does nothing, so one Return is one message.
    private var isSending = false

    /// `agents` and `bridgeExecutable` are the installed command lines and the
    /// app's bridge, and `preferences` the defaults Settings edits; a test passes stand-ins.
    init(
        store           : WorkspaceStore,
        connections     : ModelSettingsStore,
        broker          : SeatBroker,
        agents          : @escaping (ModelProvider) throws -> (ChatProvider, URL) = WorkerAgentHost.agent(for:),
        bridgeExecutable: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/braus-bridge"),
        preferences     : UserDefaults = .standard,
        channels        : AutomationChannels = [],
        chromeProfiles  : ChromeProfileHub? = nil,
        approvals       : AdapterApprovals? = nil
    ) {
        self.store            = store
        self.connections      = connections
        self.broker           = broker
        self.agents           = agents
        self.bridgeExecutable = bridgeExecutable
        self.preferences      = preferences
        self.approvals        = approvals
        var composed = channels
        if preferences.bool(forKey: AppPreferences.web) { composed.insert(.web) }
        self.channels         = composed
        self.chromeProfileHub = chromeProfiles
        pairedChromeProfiles  = chromeProfiles?.profiles ?? []
        // The hub reports from its own threads: the list the Inspector shows changes on the main actor.
        chromeProfiles?.observe { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pairedChromeProfiles = self.chromeProfileHub?.profiles ?? []
            }
        }
        self.browserWindows   = Set(
            (preferences.stringArray(forKey: AppPreferences.showsBrowserWindow) ?? []).compactMap(UUID.init)
        )
    }

    // MARK: Reading

    /// The sidebar's rows, recomputed from the team. The team is tens of
    /// workers, so this is cheaper than keeping a second copy in step.
    var rows: [TeamRow] {
        TeamOutline.rows(
            of              : active,
            modelUnavailable: workersWithRemovedModels,
            activities      : desktops.compactMapValues(\.activity),
            unread          : unread
        )
    }

    /// No model attached, or one the catalogue no longer lists (§7.4).
    func needsConfiguring(_ worker: WorkerSnapshot) -> Bool {
        !worker.isConfigured || workersWithRemovedModels.contains(worker.id)
    }

    private var workersWithRemovedModels: Set<UUID> {
        Set(modelStates.compactMap { id, state in
            if case .modelRemoved = state { id } else { nil }
        })
    }

    var selectedWorker: WorkerSnapshot? { selection.flatMap(worker) }

    func worker(_ id: UUID) -> WorkerSnapshot? {
        active.first { $0.id == id } ?? archived.first { $0.id == id }
    }

    func load() async {
        do {
            // The first load precedes every turn here: a turn a crash left unfinished ends first (§18.4).
            try await WorkerTurnRecorder.endTurnsLeftUnfinished(
                in         : store,
                workspaceID: Self.workspaceID
            )
        } catch {
            problem = issue(
                title  : "Couldn’t Update Turn",
                message: "Braus couldn’t mark a response from the previous session as stopped.",
                error  : error
            )
        }

        do {
            let everyone = try await store.workers(includingArchived: true)
            active   = everyone.filter { !$0.isArchived }
            archived = everyone.filter(\.isArchived)
        } catch {
            problem = issue(
                title  : "Couldn’t Refresh Team",
                message: "The worker list may be out of date.",
                error  : error
            )
        }

        await refreshUnread()
    }

    // MARK: The conversation

    /// Opens the selected worker's direct conversation, creating it the first
    /// time. The outgoing draft is written first, so switching worker while
    /// something is typed does not lose it.
    ///
    /// The selection can change while this waits on the store, and a later
    /// call can finish first. Each call takes a generation and, after every
    /// suspension, drops its result when a newer call has started, so an
    /// earlier reply never opens a worker that is no longer selected.
    func openSelectedConversation() async {
        openingGeneration += 1
        let generation = openingGeneration

        await flushDraft()
        guard generation == openingGeneration else { return }

        conversation    = nil
        draft           = ""
        savedDraft      = ""
        draftQuote      = nil
        savedDraftQuote = nil
        showsUsage      = false
        showsContext    = false
        observation     = nil

        guard let id = selection else { return }

        do {
            // One direct conversation per worker, found by its participant, in
            // a linear scan over the handful a person has in increment 1.
            let existing = try await store.conversations().first {
                $0.kind == .direct && $0.participantIDs == [id]
            }
            guard generation == openingGeneration else { return }

            let opened: ConversationSnapshot
            if let existing {
                opened = existing
            } else {
                opened = try await store.createConversation(
                    kind        : .direct,
                    participants: [id]
                )
                guard generation == openingGeneration else { return }
            }

            conversation    = opened
            draft           = opened.draft
            savedDraft      = opened.draft
            draftQuote      = opened.draftQuote
            savedDraftQuote = opened.draftQuote
            // The queue already held here is newer than the store's, which only follows it.
            if queues[opened.id] == nil { queues[opened.id] = opened.queue }
            await markReadIfAtEnd()
            await refreshUsage(of: id)
        } catch {
            guard generation == openingGeneration else { return }

            problem = issue(
                title  : "Couldn’t Open Conversation",
                message: "Select the worker again to retry.",
                error  : error
            )
        }
    }

    /// Whether the draft as typed, or its quote, differs from what the store holds.
    var hasUnsavedDraft: Bool {
        conversation != nil && (draft != savedDraft || draftQuote != savedDraftQuote)
    }

    /// Writes the draft and its quote where they differ from what the store
    /// holds. What is written is what they were at the call; what changes
    /// meanwhile is the next flush's, and a reply for a conversation no longer
    /// open is dropped.
    func flushDraft() async {
        guard let conversation, draft != savedDraft || draftQuote != savedDraftQuote else { return }

        let text  = draft
        let quote = draftQuote
        do {
            var updated = conversation
            if text != savedDraft {
                updated = try await store.update(
                    conversation: conversation.id,
                    .draft(text)
                )
            }
            if quote != savedDraftQuote {
                updated = try await store.update(
                    conversation: conversation.id,
                    .draftQuote(quote)
                )
            }
            guard self.conversation?.id == conversation.id else { return }

            self.conversation = updated
            savedDraft        = text
            savedDraftQuote   = quote
        } catch {
            problem = issue(
                title  : "Couldn’t Save Draft",
                message: "Keep Braus open and try again before quitting.",
                error  : error
            )
        }
    }

    /// Persists the message, then starts the worker's answer, as an agent
    /// command line or through Braus's own loop (`WorkerAnswer`), when the
    /// worker has a provider. Otherwise the message stays saved and nothing
    /// answers, and the composer says why. While the worker answers, a turn or
    /// a compaction, the message joins the conversation's queue instead, with
    /// its quote, and goes out when the turn ends (`sendShownQueued`).
    ///
    /// A draft that is a command runs as one before anything else, even while
    /// the worker answers: it never becomes a message and is never queued
    /// (`run`). A draft that starts with `//` is sent with its first `/` removed.
    ///
    /// The text and its quote leave the draft before the first suspension, and
    /// a second send while this one waits does nothing, so one Return is one
    /// message. A message the store refuses goes back into the draft with its
    /// quote: nothing typed is consumed by a failed attempt. A refused message
    /// and a saved message whose draft could not be cleared are reported as the
    /// two facts they are.
    func send() async {
        guard !isSending, let conversation else { return }

        let typed   = draft
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let command = SlashCommandInvocation(draft: trimmed) { return await run(command) }

        let text = SlashCommandInvocation.messageText(trimmed)

        let workerID = conversation.participantIDs.first
        let quote    = draftQuote
        isSending = true
        defer { isSending = false }
        draft      = ""
        draftQuote = nil

        if let workerID, isAnswering(workerID) {
            queues[conversation.id, default: []].append(QueuedMessage(
                text : text,
                quote: quote
            ))
            await saveQueue(of: conversation.id)
            await clearSavedDraft(
                of    : conversation.id,
                quote : quote,
                queued: true
            )
            return
        }

        do {
            try await post(
                text,
                quote: quote,
                in   : conversation.id,
                by   : workerID
            )
        } catch {
            problem = issue(
                title  : "Couldn’t Send Message",
                message: "The message wasn’t saved or sent. Braus will restore it to the draft.",
                error  : error
            )
            await restoreDraft(
                typed,
                quote: quote,
                in   : conversation.id
            )
            return
        }

        await clearSavedDraft(
            of    : conversation.id,
            quote : quote,
            queued: false
        )
    }

    /// Writes `text` as the person's message in `conversationID`, with the
    /// quote it replies to, then starts `workerID`'s answer when there is a
    /// worker. It reads nothing of the open conversation or the draft, so the
    /// queue sends through it for a conversation that is not on screen.
    /// `holding` says the caller already holds the worker as answering there,
    /// as the queue does from the end of one turn to the start of the next.
    /// Internal, not private, so a hosted test posts into a conversation that is not on screen.
    func post(
        _ text           : String,
        quote            : MessageQuote?,
        in conversationID: UUID,
        by workerID      : UUID?,
        holding          : Bool = false
    ) async throws {
        let message = try await store.appendMessage(
            to   : conversationID,
            text : text,
            quote: quote
        )

        if conversation?.id == conversationID { transcriptRevision += 1 }
        guard let workerID else { return }

        startAnswer(
            to     : message,
            in     : conversationID,
            by     : workerID,
            holding: holding
        )
    }

    /// Empties the stored draft and its quote once what they held was sent or
    /// queued. A failure says the text may come back after a relaunch.
    private func clearSavedDraft(
        of conversationID: UUID,
        quote            : MessageQuote?,
        queued           : Bool
    ) async {
        do {
            var cleared = try await store.update(
                conversation: conversationID,
                .draft("")
            )
            if quote != nil || savedDraftQuote != nil {
                cleared = try await store.update(
                    conversation: conversationID,
                    .draftQuote(nil)
                )
            }
            guard self.conversation?.id == conversationID else { return }

            self.conversation = cleared
            savedDraft        = ""
            savedDraftQuote   = nil
        } catch {
            problem = issue(
                title  : "Couldn’t Clear Draft",
                message: "The message was \(queued ? "queued" : "sent"), but the same text may reappear in the draft after you reopen Braus.",
                error  : error
            )
        }
    }

    /// Puts a refused message's text back where it was typed, or a queued one
    /// being edited, and its quote unless another reply was started meanwhile.
    /// Whatever was typed after it stays, below it.
    private func restoreDraft(
        _ typed          : String,
        quote            : MessageQuote?,
        in conversationID: UUID
    ) async {
        if self.conversation?.id == conversationID {
            draft      = draft.isEmpty ? typed : typed + "\n" + draft
            draftQuote = draftQuote ?? quote
            return
        }

        // The person moved to another worker meanwhile, so the text goes back
        // into the store's draft of the conversation it was written in.
        do {
            try await store.update(
                conversation: conversationID,
                .draft(typed)
            )
            try await store.update(
                conversation: conversationID,
                .draftQuote(quote)
            )
        } catch {
            problem = issue(
                title  : "Couldn’t Restore Draft",
                message: "The message wasn’t saved, and Braus couldn’t restore it to the draft. Copy this text before closing the alert:\n\n\(typed)",
                error  : error
            )
        }
    }

    // MARK: The answer

    func isAnswering(_ workerID: UUID) -> Bool { answering[workerID] != nil }

    /// The workers an adapter approval waits on the person for: each answering in a conversation that one waits
    /// in (`AdapterApprovals.waitingScopes`).
    var awaitingApproval: Set<UUID> {
        guard let scopes = approvals?.waitingScopes, !scopes.isEmpty else { return [] }

        return Set(answering.filter { scopes.contains($0.value) }.keys)
    }

    /// Starts the worker's turn when it has a provider. The turn runs apart
    /// from `send`, so writing to another worker meanwhile is not held up, and
    /// a failed turn is reported and never retried. A turn through Braus's own
    /// loop is sent the conversation before the message (`turnHistory`). A
    /// completed turn that leaves the context at 90% or more is followed by a
    /// compaction, before any next message can start.
    ///
    /// A turn that completed sends the queued message its conversation shows,
    /// after that compaction when there is one; a stopped or failed turn sends
    /// nothing, unless Send Now stopped it. `holding` says the worker is already
    /// held as answering in `conversationID`, and is let go if nothing starts.
    private func startAnswer(
        to message       : MessageSnapshot,
        in conversationID: UUID,
        by workerID      : UUID,
        holding          : Bool = false
    ) {
        guard let worker = worker(workerID), worker.configuration != nil, holding || answering[workerID] == nil
        else {
            if holding { answering[workerID] = nil }
            return
        }

        answering[workerID] = conversationID

        let (host, desktop) = agentHost(
            of : conversationID,
            for: workerID
        )

        let recorder = WorkerTurnRecorder(
            store         : store,
            workspaceID   : Self.workspaceID,
            workerID      : workerID,
            conversationID: conversationID,
            messageID     : message.id,
            withholding   : host.withheld
        ) { [weak self] in
            await self?.reloadTranscript(of: conversationID)
        }

        Task {
            await activate(conversationID, for: workerID)
            // A page held from an earlier turn under a choice of Chrome profile since changed, or in a paired profile
            // no longer connected, closes first, so this turn opens its page where the person now chose.
            await webs[conversationID]?.session.closeIfSuperseded()
            var ending: WorkerTurnRecorder.Ending?
            do {
                var provider: ModelProvider?
                let ended = try await recorder.run { frozen, session, emit in
                    provider = frozen.provider
                    if pendingStops.remove(workerID) != nil { throw CancellationError() }
                    var history: [TurnMessage] = []
                    if WorkerAnswer(provider: frozen.provider) == .modelLoop {
                        history = try await turnHistory(
                            in    : conversationID,
                            before: message.sequence,
                            by    : workerID
                        )
                    }
                    // A failed read only makes a Codex turn count from its session's start: no reason to fail it.
                    let lastUsage   = try? await store.latestTurnUsage(
                        in: conversationID,
                        on: frozen.provider
                    )
                    let searchesWeb = AppPreferences.bool(
                        AppPreferences.workersSearchWeb,
                        default: AppPreferences.workersSearchWebDefault,
                        in     : preferences
                    )
                    // The memory traces this turn's calls to the message it answers, which a task names as its origin.
                    host.callProducer.traceID    = message.id.uuidString
                    host.callProducer.messageRef = message.id.uuidString
                    // The turn gives the seat back as it ends when another entry is waiting for it.
                    try await desktop.turn {
                        try await host.run(
                            prompt         : Self.agentText(of: message),
                            selection      : frozen,
                            sessionID      : session,
                            role           : worker.instructions,
                            history        : history,
                            lastUsage      : lastUsage,
                            allowsWebSearch: searchesWeb,
                            onEvent        : emit
                        )
                    }
                }
                ending = ended
                if let provider { settle(provider, after: ended) }
            } catch {
                problem = issue(
                    title  : "Couldn’t Save Complete Response",
                    message: "Part of \(worker.name)’s response may be missing from this conversation.",
                    error  : error
                )
            }

            // The limits are the account's, so the worker on screen may share them.
            await refreshUsage(of: workerID)
            if let selection, selection != workerID { await refreshUsage(of: selection) }

            pendingStops.remove(workerID)
            let sendsNow = sendsQueuedOnEnd.remove(workerID) != nil
            // Each next step starts with no suspension after the turn ends, so no message can start a turn first.
            if ending == .completed,
               let fraction = usage[workerID]?.context?.fraction,
               UsageWording.contextLevel(fraction) == .full {
                answering[workerID] = nil
                startCompaction(
                    of     : workerID,
                    in     : conversationID,
                    trigger: .automatic
                )
            } else if ending == .completed || sendsNow {
                await sendShownQueued(
                    in: conversationID,
                    by: workerID
                )
            } else {
                answering[workerID] = nil
            }
        }
    }

    /// The conversation's agent host and the desktop its tools drive, the
    /// worker's one, made on first use and kept for the process.
    private func agentHost(
        of conversationID: UUID,
        for workerID     : UUID
    ) -> (host: WorkerAgentHost, desktop: BrokeredAutomationSession) {
        if let existing = hosts[conversationID] { return existing }

        let desktop  = desktops[workerID] ?? self.desktop(for: workerID)
        let channels = self.channels
        var web: WebAutomationSession?
        if channels.contains(.web) {
            let session = webs[conversationID]?.session
                ?? AppModel.webSession(showsWindow: browserWindows.contains(conversationID),
                                       personal   : personalChromes.contains(conversationID),
                                       profile    : chromeProfile(in: conversationID),
                                       hub        : chromeProfileHub)
            webs[conversationID] = (workerID, session)
            web = session
        }
        let host     = WorkerAgentHost(
            workingDirectory: workingFolder(of: conversationID),
            bridgeExecutable: bridgeExecutable,
            session         : { AppModel.session(desktop: desktop, channels: channels, web: web, owner: workerID) },
            channels        : channels,
            agents          : agents,
            transports      : { [connections] in $0.transport(settings: connections.providerSettings) },
            contextWindows  : { [connections] selection in
                ModelToolLoop.contextWindow(
                    of       : selection,
                    settings : connections.providerSettings,
                    catalogue: connections.catalogues[selection.provider] ?? []
                )
            },
            seatLine        : { desktop.turnStatus },
            // P2-06: what the person refused in this conversation is refused again after the app restarts.
            barrier         : ActionBarrier(persistingIn: AppModel.refusalFolder,
                                            context: "conversation-" + conversationID.uuidString),
            adapterApprover: approvals.map { AdapterApprover(approvals: $0) },
            approvals: approvals,
            approvalScope: conversationID
        )
        host.callProducer = CallProducer(source: .app, streamID: "worker-" + workerID.uuidString)
        hosts[conversationID] = (host, desktop)
        return (host, desktop)
    }

    /// Makes `conversationID` the context `workerID` acts in, as a turn or a compaction starts there (I02). When the
    /// worker last acted in another conversation, that context is retired first: its host admits no call from any
    /// connection, a call in flight finishes, and its sessions close, the worker's desktop and the conversation's page
    /// with them, so no session ID they gave is valid again and nothing is replayed. Its host, its provider session
    /// and the conversation stay, and its next turn opens what it needs again. Looking at another conversation
    /// retires nothing: only a turn that starts in it does, and the worker runs one at a time (`answering`).
    private func activate(_ conversationID: UUID, for workerID: UUID) async {
        guard let previous = activeContexts.updateValue(conversationID, forKey: workerID), previous != conversationID
        else { return }
        await hosts[previous]?.host.retire()
        await webs[previous]?.session.close()
        await desktops[workerID]?.close()
    }

    /// What a hosted test reads of a conversation's context and of the worker's.
    func agentContext(of conversationID: UUID) -> (host: WorkerAgentHost, desktop: BrokeredAutomationSession)? {
        hosts[conversationID]
    }

    func activeContext(of workerID: UUID) -> UUID? { activeContexts[workerID] }

    func desktopSession(of workerID: UUID) -> BrokeredAutomationSession? { desktops[workerID] }

    /// The conversation before `sequence` as a model provider is sent it: the
    /// person's messages as `user`, the worker's replies as `assistant`, in order,
    /// from where the context last started again (`WorkspaceStore.contextStart`).
    /// Tool calls and their results from earlier turns are not resent.
    private func turnHistory(
        in conversationID: UUID,
        before sequence  : Int,
        by workerID      : UUID
    ) async throws -> [TurnMessage] {
        // ponytail: the last 40 messages, not a token budget; count tokens when long chats outgrow the context.
        let earlier = try await store.messages(
            in    : conversationID,
            around: sequence,
            before: 40,
            after : 0
        )
        let start   = try await store.contextStart(in: conversationID)
        return Self.turnHistory(
            earlier,
            by     : workerID,
            since  : start?.date,
            summary: start?.summary
        )
    }

    /// What an agent receives for `message`, from a command line or through
    /// Braus's own loop alike: the quote it replies to as a Markdown blockquote,
    /// every line of it behind `> `, a blank line, then the message. A message
    /// that quotes nothing is its text unchanged.
    static func agentText(of message: MessageSnapshot) -> String {
        guard let quote = message.quote else { return message.text }

        let quoted = quote.text
            .split(
                omittingEmptySubsequences: false,
                whereSeparator           : \.isNewline
            )
            .map { "> " + $0 }
            .joined(separator: "\n")
        return quoted + "\n\n" + message.text
    }

    /// Maps stored messages to turn messages, each as `agentText` composes it.
    /// An empty message, one by anyone other than the person or `workerID`, and
    /// one sent before `start`, where the context last started again, are left
    /// out. `summary`, what a compaction there left, comes first, as a system message.
    static func turnHistory(
        _ messages : [MessageSnapshot],
        by workerID: UUID,
        since start: Date?   = nil,
        summary    : String? = nil
    ) -> [TurnMessage] {
        let summarized = summary.map {
            [TurnMessage(
                role: .system,
                text: ModelToolLoop.summaryPreface + $0
            )]
        } ?? []
        return summarized + messages.compactMap { message -> TurnMessage? in
            guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  start.map({ message.createdAt > $0 }) ?? true
            else { return nil }

            switch message.authorWorkerID {
            case nil:
                return TurnMessage(
                    role: .user,
                    text: agentText(of: message)
                )
            case workerID?:
                return TurnMessage(
                    role: .assistant,
                    text: agentText(of: message)
                )
            default:
                return nil
            }
        }
    }

    /// What a turn's ending says about its provider's connection. A command line that is no longer
    /// signed in fails every turn until the person signs in again, and the connection light kept
    /// reading Connected, so the alert says how and the light turns to Access Rejected; the next
    /// turn that completes checks the connection again.
    private func settle(_ provider: ModelProvider, after ending: WorkerTurnRecorder.Ending) {
        switch ending {
        case .failed(let reason):
            guard let expired = Self.signInExpired(provider: provider, reason: reason) else { return }
            connections.recordCheck(
                .credentialRejected(detail: reason),
                for: provider,
                at : Date()
            )
            problem = expired
        case .completed:
            if connections.states[provider]?.isReady == false { connections.refresh([provider]) }
        case .cancelled:
            return
        }
    }

    /// The alert for a turn that failed because its command line is signed out, nil for any other
    /// failure, as `SignInFailure` recognises it.
    static func signInExpired(
        provider: ModelProvider,
        reason  : String
    ) -> UserFacingIssue? {
        guard SignInFailure.isSignedOut(reason), let steps = SignInFailure.steps(for: provider) else { return nil }

        let name = SignInFailure.name(of: provider)
        return UserFacingIssue(
            title           : "Sign In to \(name) Again",
            message         : "\(name) on this Mac is signed out, so workers using it can’t respond. "
                + "\(steps) Then send your message again.",
            technicalDetails: reason
        )
    }

    // MARK: The context

    func isCompacting(_ workerID: UUID) -> Bool { compacting.contains(workerID) }

    /// Compacts the worker's context in its open conversation, as the context
    /// popover asks. Nothing starts while the worker answers.
    func compactContext(of workerID: UUID) {
        guard let conversation, conversation.participantIDs == [workerID] else { return }

        startCompaction(
            of     : workerID,
            in     : conversation.id,
            trigger: .manual
        )
    }

    /// Starts the worker's context over with nothing from before now, once the
    /// person confirmed: a command line's session is forgotten, so the next turn
    /// starts a new one, and Braus's loop is sent only what follows. The chat
    /// stays as it is. Nothing happens while the worker answers.
    func startFreshContext(of workerID: UUID) async {
        guard let conversation, conversation.participantIDs == [workerID], answering[workerID] == nil
        else { return }

        do {
            let cleared = try await store.update(
                conversation: conversation.id,
                .providerSessionCleared
            )
            if self.conversation?.id == cleared.id { self.conversation = cleared }
            try await appendContextEvent(
                .contextReset,
                of: workerID,
                in: conversation.id
            )
            await reloadTranscript(of: conversation.id)
        } catch {
            problem = issue(
                title  : "Couldn’t Start Fresh Context",
                message: "\(name(of: workerID)) may still remember the conversation before now.",
                error  : error
            )
        }
        await refreshUsage(of: workerID)
    }

    /// Compacts the worker's context in `conversationID` as a turn of its own,
    /// through the conversation's agent host (`WorkerAgentHost.compact`). It
    /// starts only while the worker is not answering, and a message sent
    /// meanwhile waits in the composer, as one does behind a running turn. It
    /// records `contextCompacted`, with a Codex compaction's usage before it, and
    /// never a message.
    ///
    /// A failure leaves the context as it was and is not retried here. The
    /// person is told of one they asked for, and of a signed-out command line
    /// whoever asked; an automatic one is logged, and the next completed turn at
    /// 90% or more tries again.
    ///
    /// Once it ends, the queued message its conversation shows goes out, unless
    /// the person stopped it or a compaction they asked for failed, as after a
    /// turn; Send Now sends it either way.
    private func startCompaction(
        of workerID      : UUID,
        in conversationID: UUID,
        trigger          : ContextCompaction.Trigger
    ) {
        guard let worker = worker(workerID), let selection = worker.configuration, answering[workerID] == nil
        else { return }

        answering[workerID] = conversationID
        compacting.insert(workerID)
        let host = agentHost(
            of : conversationID,
            for: workerID
        ).host

        Task {
            await activate(conversationID, for: workerID)
            var compacted: (compaction: ContextCompaction, usage: TurnUsage?)?
            var stopped = false
            do {
                let stored    = try await store.conversation(conversationID)
                // A failed read only makes a Codex compaction count from its session's start.
                let lastUsage = try? await store.latestTurnUsage(
                    in: conversationID,
                    on: selection.provider
                )
                var history: [TurnMessage] = []
                if WorkerAnswer(provider: selection.provider) == .modelLoop {
                    history = try await turnHistory(
                        in    : conversationID,
                        before: .max,
                        by    : workerID
                    )
                }
                if pendingStops.remove(workerID) != nil { throw CancellationError() }
                compacted = try await host.compact(
                    selection: selection,
                    sessionID: stored?.resumableSession(for: selection.provider),
                    role     : worker.instructions,
                    trigger  : trigger,
                    history  : history,
                    lastUsage: lastUsage
                )
            } catch is CancellationError {
                // A stopped compaction leaves the context as it was, and says nothing.
                stopped = true
            } catch {
                compactionFailed(
                    error,
                    of     : worker,
                    on     : selection.provider,
                    trigger: trigger
                )
            }

            if let compacted {
                do {
                    if var usage = compacted.usage {
                        usage.isCompaction = true
                        try await appendContextEvent(
                            .turnUsage,
                            of     : workerID,
                            in     : conversationID,
                            payload: try usage.encoded(),
                            version: TurnUsage.payloadVersion
                        )
                    }
                    try await appendContextEvent(
                        .contextCompacted,
                        of     : workerID,
                        in     : conversationID,
                        payload: try compacted.compaction.encoded(),
                        version: ContextCompaction.payloadVersion
                    )
                    await reloadTranscript(of: conversationID)
                } catch {
                    problem = issue(
                        title  : "Couldn’t Record Compaction",
                        message: "\(worker.name)’s context was compacted, but the context shown may be out of date.",
                        error  : error
                    )
                }
            }

            await refreshUsage(of: workerID)
            compacting.remove(workerID)
            pendingStops.remove(workerID)
            let sendsNow = sendsQueuedOnEnd.remove(workerID) != nil
            if sendsNow || (!stopped && (compacted != nil || trigger == .automatic)) {
                await sendShownQueued(
                    in: conversationID,
                    by: workerID
                )
            } else {
                answering[workerID] = nil
            }
        }
    }

    /// Tells the person of a failed compaction they asked for, and of a
    /// signed-out command line whoever asked, the way a failed turn does;
    /// logs any other.
    private func compactionFailed(
        _ error    : any Error,
        of worker  : WorkerSnapshot,
        on provider: ModelProvider,
        trigger    : ContextCompaction.Trigger
    ) {
        let reason = (error as? AutomationFailure)?.description ?? error.localizedDescription
        if Self.signInExpired(provider: provider, reason: reason) != nil {
            settle(provider, after: .failed(reason: reason))
        } else if trigger == .manual {
            problem = UserFacingIssue(
                title           : "Couldn’t Compact Context",
                message         : "\(worker.name)’s context is as it was. Try again, or start a fresh context.",
                technicalDetails: reason
            )
        } else {
            Self.log.error("An automatic compaction failed and waits for the next turn: \(reason, privacy: .public)")
        }
    }

    /// Records a context event with the conversation as its subject: a
    /// compaction, a fresh context, or what a compaction turn cost.
    private func appendContextEvent(
        _ type           : EventType,
        of workerID      : UUID,
        in conversationID: UUID,
        payload          : Data? = nil,
        version          : Int   = 1
    ) async throws {
        try await store.append(NewEvent(
            workspaceID   : Self.workspaceID,
            subjectID     : conversationID,
            conversationID: conversationID,
            workerID      : workerID,
            type          : type,
            payloadVersion: version,
            payload       : payload
        ))
    }

    /// Stops the worker's running turn, as Stop in the conversation and in
    /// the menus asks. What already arrived stays, and the turn ends with the
    /// interruption note. A compaction stops the same way and leaves the context as it was.
    func stopAnswering(_ workerID: UUID) {
        guard let conversationID = answering[workerID] else { return }

        if let host = hosts[conversationID]?.host, host.isRunning {
            host.stop()
        } else {
            pendingStops.insert(workerID)
        }
    }

    // MARK: The queue

    /// The open conversation's queue, in order.
    var queue: [QueuedMessage] { conversation.flatMap { queues[$0.id] } ?? [] }

    /// Where the open conversation's strip stands in its queue: the message it
    /// shows, which is the one that goes next.
    var shownQueuedIndex: Int { conversation.map { shownIndex(in: $0.id) } ?? 0 }

    private func shownIndex(in conversationID: UUID) -> Int {
        let count = queues[conversationID]?.count ?? 0
        return min(
            shownQueued[conversationID] ?? 0,
            max(count - 1, 0)
        )
    }

    /// Shows the next queued message in the open conversation's strip, and
    /// after the last one the first again.
    func showNextQueued() {
        guard let conversation, let count = queues[conversation.id]?.count, count > 1 else { return }

        shownQueued[conversation.id] = (shownIndex(in: conversation.id) + 1) % count
    }

    /// Sends the queued message the open conversation's strip shows at once. A
    /// running turn or compaction is stopped first, as Stop stops it, and the
    /// message goes out as soon as it has ended.
    func sendQueuedNow() async {
        guard let conversation, let workerID = conversation.participantIDs.first, !queue.isEmpty else { return }

        if isAnswering(workerID) {
            sendsQueuedOnEnd.insert(workerID)
            stopAnswering(workerID)
        } else {
            await sendShownQueued(
                in: conversation.id,
                by: workerID
            )
        }
    }

    /// Takes the queued message the open conversation's strip shows out of the queue.
    func removeShownQueued() async {
        guard let conversation, takeShownQueued(from: conversation.id) != nil else { return }

        await saveQueue(of: conversation.id)
    }

    /// Moves the queued message the open conversation's strip shows back into
    /// the draft to be edited, as `restoreDraft` puts text back. The draft is
    /// saved before the queue, so a quit between the two keeps the text twice
    /// rather than losing it.
    func editShownQueued() async {
        guard let conversation, let taken = takeShownQueued(from: conversation.id) else { return }

        await restoreDraft(
            taken.message.text,
            quote: taken.message.quote,
            in   : conversation.id
        )
        await flushDraft()
        await saveQueue(of: conversation.id)
    }

    /// Sends the queued message `conversationID`'s strip shows, and keeps the
    /// rest queued, the strip then showing the first of them. The worker is
    /// held as answering from before the message is written until its turn
    /// starts, so nothing else starts a turn in between and a message sent
    /// meanwhile joins the queue. A message the store refuses goes back where
    /// it was in the queue, and the worker is let go, as it is when the queue is empty.
    private func sendShownQueued(
        in conversationID: UUID,
        by workerID      : UUID
    ) async {
        guard let taken = takeShownQueued(from: conversationID) else {
            answering[workerID] = nil
            return
        }

        answering[workerID] = conversationID
        do {
            try await post(
                taken.message.text,
                quote  : taken.message.quote,
                in     : conversationID,
                by     : workerID,
                holding: true
            )
        } catch {
            answering[workerID] = nil
            var queue = queues[conversationID] ?? []
            queue.insert(
                taken.message,
                at: min(taken.index, queue.count)
            )
            queues[conversationID] = queue
            problem = issue(
                title  : "Couldn’t Send Queued Message",
                message: "The message is still queued. Send it again from the queue.",
                error  : error
            )
            return
        }

        await saveQueue(of: conversationID)
    }

    /// Removes the message a conversation's strip shows from its queue, which
    /// then shows the first one, and returns it with the place it had.
    private func takeShownQueued(from conversationID: UUID) -> (message: QueuedMessage, index: Int)? {
        guard var queue = queues[conversationID], !queue.isEmpty else { return nil }

        let index   = shownIndex(in: conversationID)
        let message = queue.remove(at: index)
        queues[conversationID]      = queue
        shownQueued[conversationID] = nil
        return (message, index)
    }

    /// Writes the conversation's queue as it is now. A refusal leaves the queue
    /// working in this session and says it may not outlast it.
    private func saveQueue(of conversationID: UUID) async {
        do {
            try await store.update(
                conversation: conversationID,
                .queue(queues[conversationID] ?? [])
            )
        } catch {
            problem = issue(
                title  : "Couldn’t Save Queued Messages",
                message: "They will still be sent in this session, but may be gone after you quit Braus.",
                error  : error
            )
        }
    }

    /// A new desktop session for the worker, kept so its row can read it. It
    /// waits in the queue under the worker's id, never its name, so two workers
    /// with one name each read their own position. The Brain's directory is the
    /// command line's, so what either learns applies to both.
    private func desktop(for workerID: UUID) -> BrokeredAutomationSession {
        let desktop = BrokeredAutomationSession(
            broker            : broker,
            workerID          : workerID,
            knowledgeDirectory: WorkspaceLaunch.directory.appending(
                path         : "Knowledge",
                directoryHint: .isDirectory
            )
        )
        desktops[workerID] = desktop
        return desktop
    }

    /// What the worker is doing with the computer, in the words its row shows; nil while nothing.
    func activity(of workerID: UUID) -> String? { desktops[workerID]?.activity }

    /// True while the worker's desktop session holds the seat, the only time it can be released.
    func holdsComputer(_ workerID: UUID) -> Bool { desktops[workerID]?.holdsComputer ?? false }

    /// True while the worker's window can be watched: it holds the seat and has an application open.
    func hasScreen(_ workerID: UUID) -> Bool { desktops[workerID]?.hasScreen ?? false }

    /// A live view of the worker's window, nil while there is none; see `hasScreen`.
    func makeScreenView(
        of workerID  : UUID,
        contentsScale: CGFloat
    ) -> NSView? {
        desktops[workerID]?.makeScreenView(contentsScale: contentsScale)
    }

    /// The worker's window frame, for the live view's proportions.
    func screenFrame(of workerID: UUID) -> CGRect { desktops[workerID]?.screenFrame ?? .zero }

    /// Whether the worker's live screen floats over the conversation instead of sitting in the inspector.
    var showsScreenInConversation = false

    /// The worker's screen enlarged over the conversation, nil while it is small.
    var enlargedScreen: ScreenEnlargement?

    /// The workers whose screen shows in its own window; their small views stay paused, so the
    /// stream is drawn once.
    private(set) var windowedScreens: Set<UUID> = []

    /// Records that the worker's screen window opened or closed.
    func setScreenWindowed(
        _ workerID : UUID,
        _ isWindowed: Bool
    ) {
        if isWindowed { windowedScreens.insert(workerID) } else { windowedScreens.remove(workerID) }
    }

    /// The small live views on screen, by place: where the enlarged one grows from and shrinks into.
    @ObservationIgnored
    private var smallScreens: [ScreenPlace: WeakScreenView] = [:]

    /// Records the small live view that now sits in `place`.
    func registerScreenView(
        _ view: NSView,
        in place: ScreenPlace
    ) {
        smallScreens[place] = WeakScreenView(view: view)
    }

    /// The small live view in `place`, nil while there is none.
    func screenView(in place: ScreenPlace) -> NSView? { smallScreens[place]?.view }

    /// Enlarges the worker's screen from `place`; nothing while it is already enlarged or has no window.
    func enlargeScreen(
        of workerID: UUID,
        from place : ScreenPlace
    ) {
        guard enlargedScreen == nil, hasScreen(workerID) else { return }

        enlargedScreen = ScreenEnlargement(
            workerID: workerID,
            origin  : place
        )
    }

    /// Asks the enlarged screen to shrink back; the overlay finishes it when it has landed.
    func closeEnlargedScreen() { enlargedScreen?.close() }

    /// Removes the enlarged screen at once, for a worker or a seat that went away.
    func dismissEnlargedScreen() { enlargedScreen = nil }

    /// Whether the conversation shows Braus's Chrome as a window.
    func showsBrowserWindow(in conversationID: UUID) -> Bool { browserWindows.contains(conversationID) }

    /// Shows or hides Braus's Chrome for the conversation, from the next time it starts. A Chrome already
    /// running between turns is closed, so the next page opens the way the person chose; during a turn it
    /// is left alone and the choice applies once it closes.
    func setShowsBrowserWindow(_ shows: Bool, in conversationID: UUID) async {
        if shows { browserWindows.insert(conversationID) } else { browserWindows.remove(conversationID) }
        preferences.set(browserWindows.map(\.uuidString), forKey: AppPreferences.showsBrowserWindow)
        guard let web = webs[conversationID] else { return }
        web.session.launchOptions = AppModel.chromeOptions(showsWindow: shows)
        if !isAnswering(web.workerID) { await web.session.close() }
    }

    /// Whether the conversation opens its pages in the person's own Chrome.
    func usesPersonalChrome(in conversationID: UUID) -> Bool { personalChromes.contains(conversationID) }

    /// Opens the conversation's pages in the person's own Chrome, or in Braus's again, from the next page it opens.
    /// A browser held between turns is closed (Braus's Chrome quits; in the person's, only the tab Braus opened
    /// closes), so the next page opens in the one the person chose; during a turn it is left alone and the choice
    /// applies once it closes.
    func setUsesPersonalChrome(_ uses: Bool, in conversationID: UUID) async {
        if uses { personalChromes.insert(conversationID) } else { personalChromes.remove(conversationID) }
        preferences.set(personalChromes.map(\.uuidString), forKey: AppPreferences.usesPersonalChrome)
        guard let web = webs[conversationID] else { return }
        web.session.usesPersonalChrome = uses
        if !isAnswering(web.workerID) { await web.session.close() }
    }

    /// The paired Chrome profile the conversation opens its pages in, under the name the person last confirmed for
    /// it; nil for none.
    func chromeProfile(in conversationID: UUID) -> ChromeProfileChoice? {
        guard let choice = chromeProfileChoices[conversationID] else { return nil }
        let label = pairedChromeProfiles.first { $0.instanceID == choice.instanceID }?.label ?? choice.label
        return ChromeProfileChoice(instanceID: choice.instanceID, label: label)
    }

    /// Opens the conversation's pages in the paired Chrome profile `choice`, or nil for none, from the next page it
    /// opens. A browser held between turns is closed (in a profile, only the tab Braus opened closes). During a turn
    /// the session refuses its next calls on the page it holds, with nothing sent, and the next turn opens its page
    /// where the person now chose (`WebAutomationSession.closeIfSuperseded`).
    func setChromeProfile(_ choice: ChromeProfileChoice?, in conversationID: UUID) async {
        chromeProfileChoices[conversationID] = choice
        preferences.set(
            Dictionary(uniqueKeysWithValues: chromeProfileChoices.map { conversation, choice in
                (conversation.uuidString, [choice.instanceID, choice.label])
            }),
            forKey: AppPreferences.chromeProfiles
        )
        guard let web = webs[conversationID] else { return }
        web.session.chromeProfile = choice
        if !isAnswering(web.workerID) { await web.session.close() }
    }

    /// The choices `AppPreferences.chromeProfiles` holds: by conversation, the instance's ID and the name.
    private static func storedChromeProfiles() -> [UUID: ChromeProfileChoice] {
        let stored = UserDefaults.standard.dictionary(forKey: AppPreferences.chromeProfiles) as? [String: [String]]
        return (stored ?? [:]).reduce(into: [:]) { choices, entry in
            guard let conversation = UUID(uuidString: entry.key), entry.value.count == 2 else { return }
            choices[conversation] = ChromeProfileChoice(instanceID: entry.value[0], label: entry.value[1])
        }
    }

    /// Gives the worker's seat back (§3.4). The conversation, a running turn and the worker stay
    /// as they are; the next tool call that needs the computer waits in the queue for it again.
    func releaseComputer(_ workerID: UUID) async {
        await desktops[workerID]?.close()
        for web in webs.values where web.workerID == workerID { await web.session.close() }
    }

    /// Reads the worker's window as the agent's `observe` reads it, for `/observe`. It
    /// does not take the seat: with no session open there is nothing to read.
    func observeScreen(of workerID: UUID) async {
        guard let desktop = desktops[workerID] else { return }

        do {
            let observed = try await desktop.observeWithImage()
            guard let image = observed.image else { throw AutomationFailure("The scene came without its frame.") }

            observation = (observed.scene, image)
        } catch {
            problem = issue(
                title  : "Couldn’t Read the Screen",
                message: "Braus couldn’t read the window the worker is using.",
                error  : error
            )
        }
    }

    /// The worker's current or last turn, with the settings it ran with. Nil before its first.
    func latestTurn(of workerID: UUID) async throws -> TurnSummary? {
        try await TurnSummary.latest(
            of       : workerID,
            in       : store,
            isRunning: isAnswering(workerID)
        )
    }

    /// True while an agent host is kept: it may hold a temporary directory, and a loopback port during a turn.
    var hasAgentHosts: Bool { !hosts.isEmpty }

    /// Ends every agent host before quitting: a running turn stops, the
    /// loopback hosts close and their temporary directories go. A directory
    /// that could not be removed is reported rather than forgotten.
    func closeAgentHosts() async {
        let closing = hosts
        let pages   = webs.values.map(\.session)
        hosts.removeAll()
        desktops.removeAll()
        webs.removeAll()
        // Chrome quits with its sessions, so no browser outlives the app.
        for web in pages { await web.close() }
        activeContexts.removeAll()
        for (host, _) in closing.values {
            do { try await host.close() }
            catch {
                problem = issue(
                    title  : "Couldn’t Remove Temporary Files",
                    message: "Some temporary worker files may remain on this Mac.",
                    error  : error
                )
            }
        }
    }

    /// Tells the transcript the open conversation changed; a turn in another
    /// conversation changes only the badges.
    private func reloadTranscript(of conversationID: UUID) async {
        guard conversation?.id == conversationID else { return await refreshUnread() }

        transcriptRevision += 1
        await markReadIfAtEnd()
    }

    /// Moves the open conversation's read marker while its reading position
    /// is the end, which is where the transcript follows new replies, then
    /// rereads the badges. A conversation read higher up keeps its count.
    private func markReadIfAtEnd() async {
        if let conversation, conversation.readingAnchorMessageID == nil {
            do {
                try await store.markRead(conversation: conversation.id)
            } catch {
                problem = issue(
                    title  : "Couldn’t Mark Conversation as Read",
                    message: "Its unread badge may remain until the next refresh.",
                    error  : error
                )
            }
        }
        await refreshUnread()
    }

    /// Rereads what the worker's turns used, on the provider it answers with now.
    private func refreshUsage(of workerID: UUID) async {
        do {
            usage[workerID] = try await store.usage(
                of: workerID,
                on: worker(workerID)?.configuration?.provider,
                in: Self.workspaceID
            )
        } catch {
            problem = issue(
                title  : "Couldn’t Update Usage",
                message: "The token counts shown for \(name(of: workerID)) may be out of date.",
                error  : error
            )
        }
    }

    private func refreshUnread() async {
        do {
            unread = try await store.unreadByWorker()
        } catch {
            problem = issue(
                title  : "Couldn’t Update Unread Counts",
                message: "Unread badges may be out of date.",
                error  : error
            )
        }
    }

    /// Remembers the message the reader is anchored on and the offset in
    /// points from its top to the viewport's top. Nil means the end.
    func rememberReadingPosition(
        _ anchor: UUID?,
        offset  : Double
    ) async {
        guard let conversation,
              conversation.readingAnchorMessageID != anchor || conversation.readingOffset != offset
        else { return }

        do {
            let updated = try await store.update(
                conversation: conversation.id,
                .readingPosition(
                    anchorMessageID: anchor,
                    offset         : offset
                )
            )
            guard self.conversation?.id == conversation.id else { return }

            self.conversation = updated
            if anchor == nil { await markReadIfAtEnd() }
        } catch {
            problem = issue(
                title  : "Couldn’t Save Reading Position",
                message: "This conversation may reopen at a different message.",
                error  : error
            )
        }
    }

    // MARK: The model

    /// Writes `selection` as the worker's next configuration version. The
    /// versions before it stay, and the change applies from the next turn.
    /// The connection and the model are checked again afterwards, so what the
    /// profile and the row say follows the change.
    func configure(
        _ id     : UUID,
        selection: ModelSelection
    ) async {
        do {
            try await store.configure(
                worker   : id,
                selection: selection
            )
            await load()
        } catch {
            problem = issue(
                title  : "Couldn’t Change Model",
                message: "\(name(of: id)) will keep the current model.",
                error  : error
            )
            return
        }

        connections.refresh([selection.provider])
        await refreshUsage(of: id)
        await checkModel(of: id)
    }

    /// Moves the worker to `provider`, with the model the provider comes with: its default from the
    /// catalogue, else the first listed, at the model's own starting effort. The model and the
    /// effort are then changed from the composer. A provider that lists no model leaves the
    /// worker where it was, and says so.
    func changeProvider(
        of id       : UUID,
        to provider : ModelProvider
    ) async {
        guard let worker = worker(id), worker.configuration?.provider != provider else { return }

        let catalogue = (try? await connections.loadCatalogue(for: provider)) ?? []
        guard let model = provider.startingModel(in: catalogue) else {
            let reason = connections.modelsUnavailable(for: provider)
                ?? "\(provider.title) didn’t return any models, so \(worker.name) will keep the current provider."
            problem = UserFacingIssue(
                title  : "No Models Available",
                message: reason
            )
            return
        }

        await configure(
            id,
            selection: ModelSelection(
                provider: provider,
                model   : model.id,
                effort  : model.startingEffort
            )
        )
    }

    /// Asks the worker's provider whether its model is still in the catalogue.
    /// A worker whose model is gone keeps it; only the person replaces it.
    func checkModel(of id: UUID) async {
        guard let selection = worker(id)?.configuration else {
            modelStates[id] = nil
            return
        }

        let state = await connections.check(
            selection.provider,
            model: selection.model
        )
        // The worker was reconfigured meanwhile, and this answer is about the old model.
        guard worker(id)?.configuration == selection else { return }

        modelStates[id] = state
    }

    /// Archiving is the ordinary removal from the active team. The worker,
    /// its conversation and its attributions stay readable in the archive.
    func setArchived(
        _ isArchived: Bool,
        for id      : UUID
    ) async {
        do {
            try await store.update(
                worker: id,
                .archived(isArchived)
            )
            if isArchived, selection == id {
                selection = nil
                await openSelectedConversation()
            }
            await load()
        } catch {
            problem = issue(
                title  : isArchived ? "Couldn’t Archive Worker" : "Couldn’t Restore Worker",
                message: isArchived
                    ? "The worker is still on the active team."
                    : "The worker is still archived.",
                error: error
            )
        }
    }

    /// Deletes the worker for good (§4.4), once the person has confirmed what
    /// goes with it. A worker still answering is not deleted, since its turn
    /// would go on writing into a conversation that is gone. Its seat is given
    /// back and its conversation closed first, and its working folder goes to
    /// the Trash, where the files it wrote can still be taken back.
    func deleteWorker(_ id: UUID) async {
        let name = name(of: id)
        guard !isAnswering(id) else {
            problem = UserFacingIssue(
                title  : "Worker Is Responding",
                message: "Stop \(name)’s response, then delete the worker again."
            )
            return
        }

        await releaseComputer(id)
        desktops[id] = nil
        activeContexts[id] = nil

        if selection == id {
            selection = nil
            await openSelectedConversation()
        }

        let conversations: [UUID]
        do {
            conversations = try await store.deleteWorker(id)
        } catch {
            problem = issue(
                title  : "Couldn’t Delete Worker",
                message: "\(name) and its data are still available.",
                error  : error
            )
            return
        }

        modelStates[id] = nil
        usage[id]       = nil
        for conversationID in conversations {
            queues[conversationID]      = nil
            shownQueued[conversationID] = nil
            if let host = hosts.removeValue(forKey: conversationID)?.host {
                do { try await host.close() }
                catch {
                    problem = issue(
                        title  : "Couldn’t Remove Temporary Files",
                        message: "Some temporary files for \(name) may remain on this Mac.",
                        error  : error
                    )
                }
            }
            trashWorkingFolder(of: conversationID)
        }
        await load()
    }

    /// Where the agent works for the conversation, and keeps the files it writes.
    private func workingFolder(of conversationID: UUID) -> URL {
        WorkspaceLaunch.directory.appending(
            path         : "WorkerWorkspaces/\(conversationID.uuidString)",
            directoryHint: .isDirectory
        )
    }

    /// Moves a deleted conversation's working folder to the Trash, when it has one.
    private func trashWorkingFolder(of conversationID: UUID) {
        let folder = workingFolder(of: conversationID)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }

        do {
            try FileManager.default.trashItem(
                at              : folder,
                resultingItemURL: nil
            )
        } catch {
            problem = issue(
                title  : "Couldn’t Move Folder to Trash",
                message: "The worker was deleted, but its folder remains at \(folder.path(percentEncoded: false)).",
                error  : error
            )
        }
    }

    // MARK: Refusals

    func issue(
        title  : String,
        message: String,
        error  : any Error
    ) -> UserFacingIssue {
        UserFacingIssue(
            title           : title,
            message         : message,
            technicalDetails: technicalDetail(error)
        )
    }

    /// Keeps diagnostic context available without making it the alert's main message.
    private func technicalDetail(_ error: any Error) -> String {
        guard let refusal = error as? WorkspaceStoreError else { return String(describing: error) }

        switch refusal {
        case .workerNotFound:
            return "The worker no longer exists in the workspace."

        case .conversationNotFound:
            return "The conversation no longer exists in the workspace."

        case .messageNotFound:
            return "The message no longer exists in the workspace."

        case .workerNotConfigured(let id):
            return "\(name(of: id)) has no provider or model."

        case .openFailed(let underlying):
            return "The workspace couldn’t be opened. \(underlying)"

        case .migrationFailed(let underlying, let restoreFailure):
            let restore = restoreFailure.map { " The previous version couldn’t be restored: \($0)" } ?? ""
            return "The workspace couldn’t be upgraded. \(underlying)\(restore)"
        }
    }

    private func name(of id: UUID) -> String {
        worker(id)?.name ?? "That worker"
    }


}

/// A small live view held without keeping it alive; the card that made it owns it.
private struct WeakScreenView {

    weak var view: NSView?
}
