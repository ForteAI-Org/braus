//
//  HouseLiveConversation.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import ModelTransports
import SwiftUI

/// HouseLiveConversation is a worker's conversation in the house window (`HouseShellView`): the
/// worker standing at the top (`HouseHero`) over the transcript (`TranscriptHost` and
/// `TranscriptController`), and the composer floating over the transcript's foot
/// (`ConversationComposer`).
///
/// The hero reads the team: its light is the worker's status as the house's rooms show it
/// (`HouseRoster`), its subtitle what the worker is doing (its running tool step, the desktop's
/// activity, or "Working") or its role; it listens while the person writes to it between turns, sets
/// about a message each time a turn starts and acts the turn out with its body (`action`). The
/// transcript and the composer keep every behaviour of the conversation: windows of history,
/// reading position, replies, the queue, slash commands, the model popup, Stop and Release. Messages fly across it
/// (`HouseLiveFlights`): a sent one into its bubble, a queued one into and out of the queue strip,
/// a quote into the reply strip and back.
///
/// A change of worker plays `HouseSwitch`. The window
/// has one transcript, so the leaving side is only its hero, which drops into the capsule while the
/// arriving one hops out of it, and a still of its transcript (`HouseTranscriptStill`): the
/// transcript hides under the still until it has opened the arriving conversation, then fades in as
/// the still fades out. The composer and the toolbar are the same views throughout, so they never
/// move and the keyboard stays where the selection put it. Changed again meanwhile, the hero shown
/// leaves and the one leaving before it goes; a still not yet faded keeps what it showed.
struct HouseLiveConversation: View {

    @Bindable
    var team: TeamModel

    let worker: WorkerSnapshot

    /// A count that puts the keyboard in the composer's field each time it moves.
    var focusRequest = 0

    /// Made once for the view and kept while it lives; opening another conversation reuses it.
    @State private var transcript: TranscriptController?

    /// The composer's height, its ground included, which the transcript keeps clear below its last message.
    @State private var composerHeight: CGFloat = 0

    /// The title bar's height, which the floating screen keeps clear.
    @State private var titleBarHeight: CGFloat = 0

    /// Moves each time a reply starts, which puts the keyboard in the composer's field.
    @State private var composerFocus = 0

    /// Moves each time a turn starts, which the hero plays as the worker setting about the message.
    @State private var preparation = 0

    /// The hero's beats a turn's rows cannot hold: reading the message just sent, the reply landing.
    @State private var isReading = false
    @State private var isLanding = false

    /// The flights of sent, queued and quoted messages over the conversation.
    @State private var flights = HouseLiveFlights()

    /// The worker the hero showed last, which `worker` replaces once its change has been seen.
    @State private var lastShownID: UUID?

    /// The worker whose hero is leaving, until `HouseSwitch.crossFade` has passed.
    @State private var departingID: UUID?

    /// The leaving transcript as it was drawn, over the arriving one until it has faded out.
    @State private var still: Still?

    /// Whether the transcript waits, hidden under `still`, to show the arriving worker's conversation.
    @State private var isArriving = false

    /// Still is the leaving transcript's image, and whether it showed the empty state over it.
    struct Still {
        let image  : NSImage?
        let isEmpty: Bool
    }

    /// The longest the transcript stays hidden after a change of worker, should its conversation not open.
    static let arrivalLimit = 1.5

    var body: some View {
        let isAnswering = team.isAnswering(worker.id)
        VStack(spacing: 0) {
            ZStack {
                ForEach(
                    heroes,
                    id: \.id
                ) { shown in
                    hero(
                        shown,
                        isAnswering: isAnswering
                    )
                    .environment(
                        \.houseSwitchPrevious,
                        shown.id == worker.id ? leaving : nil
                    )
                }
            }
            .background {
                // Each worker's edges of `isAnswering` and of its turn are its own.
                Color.clear
                    .onChange(of: isAnswering) { was, now in
                        if now, !was {
                            preparation += 1
                            isReading    = true
                        }
                    }
                    .onChange(of: transcript?.runningTurn) { was, now in
                        if Self.landsReply(
                            wasRunning   : was != nil,
                            isRunning    : now != nil,
                            endsWithReply: Self.isReply(transcript?.rows.last?.item.kind),
                            isShown      : isArrivalOpen
                        ) {
                            isLanding = true
                        }
                    }
                    .id(worker.id)
            }
            .task(id: isReading) {
                guard isReading else { return }
                try? await Task.sleep(for: .seconds(WorkerAction.reading.duration))
                isReading = false
            }
            .task(id: isLanding) {
                guard isLanding else { return }
                try? await Task.sleep(for: .seconds(WorkerAction.replying.duration))
                isLanding = false
            }
            .padding(
                .top,
                6
            )
            // In a stack of its own: on the transcript area, a Group, the overlay would go to each branch
            // and the composer would be made again, dropping the keyboard, when the transcript first opens.
            ZStack { transcriptArea }
                .overlay(alignment: .bottom) {
                    ConversationComposer(
                        team        : team,
                        worker      : worker,
                        height      : $composerHeight,
                        focusRequest: composerFocus + focusRequest,
                        reveal      : { transcript?.revealQuoted($0) },
                        flights     : flights
                    )
                }
        }
        .coordinateSpace(.named(BubbleFlight.space))
        .overlay { flights.overlay }
        .onChange(of: team.queue) { old, new in
            flights.queueChanged(
                from: old,
                to  : new,
                in  : team.conversation?.id
            )
        }
        .overlay(alignment: .topTrailing) {
            ConversationFloatingScreen(
                team          : team,
                worker        : worker,
                titleBarHeight: titleBarHeight
            )
        }
        .background(TitleBarHeightReader { titleBarHeight = $0 })
        .onAppear { lastShownID = worker.id }
        .onChange(of: worker.id) { leaveTranscript() }
        .task(id: worker.id) {
            try? await Task.sleep(for: .seconds(HouseSwitch.crossFade))
            guard !Task.isCancelled else { return }

            departingID = nil
            try? await Task.sleep(for: .seconds(Self.arrivalLimit - HouseSwitch.crossFade))
            guard !Task.isCancelled else { return }

            isArriving = false
        }
        .onChange(of: isArrivalOpen) {
            if isArrivalOpen { isArriving = false }
        }
        .task(id: isArriving) {
            guard !isArriving, still != nil else { return }
            try? await Task.sleep(for: .seconds(HouseSwitch.crossFade))
            guard !Task.isCancelled else { return }

            still = nil
        }
    }

    // MARK: Switch

    /// The worker whose hero leaves: the one shown last, from the frame that changes worker, before
    /// `onChange` has seen it.
    private var leavingID: UUID? {
        let leaving = lastShownID != worker.id ? lastShownID : departingID
        return leaving == worker.id ? nil : leaving
    }

    /// The leaving worker as its room shows it; nil once it has no room.
    private var leaving: HouseWorker? {
        leavingID.flatMap { id in HouseRoster.workers(of: team).first { $0.id == id } }
    }

    /// The heroes at the top: the leaving one under the chosen one.
    private var heroes: [HouseWorker] {
        [leaving, houseWorker].compactMap { $0 }
    }

    /// `shown`'s hero: the chosen worker's acts out its conversation; a leaving one drops into the capsule.
    private func hero(
        _ shown    : HouseWorker,
        isAnswering: Bool
    ) -> HouseHero {
        let isChosen = shown.id == worker.id
        return HouseHero(
            worker     : shown,
            status     : shown.status,
            brows      : isChosen ? Self.brows(
                status     : shown.status,
                isAnswering: isAnswering,
                draft      : team.draft
            ) : BrowState(shown.status),
            activity   : isChosen ? (isAnswering ? transcript?.runningStep : nil) ?? shown.subtitle : shown.subtitle,
            preparation: preparation,
            action     : isChosen ? Self.action(
                isAnswering: isAnswering,
                isReading  : isReading,
                isLanding  : isLanding,
                turn       : transcript?.runningTurn
            ) : nil,
            stage      : isChosen ? .present : .leaving
        )
    }

    /// Whether the transcript shows the chosen worker's conversation, opened since the change.
    private var isArrivalOpen: Bool {
        guard let conversation = team.conversation, conversation.participantIDs == [worker.id] else { return false }
        return transcript?.shownConversationID == conversation.id
    }

    /// Hides the transcript under a still of what it shows until the arriving conversation is open;
    /// a still that has not faded yet stays, since the transcript under it still shows the same.
    private func leaveTranscript() {
        departingID = leavingID
        lastShownID = worker.id
        if !isArriving || still == nil, let transcript {
            still = Still(
                image  : HouseTranscriptStill.image(of: transcript.view),
                isEmpty: transcript.isEmpty
            )
        }
        isArriving = true
    }

    /// The hero's brows: listening while the person writes to a worker that is not answering,
    /// otherwise the expression of its status.
    static func brows(
        status     : WorkerStatus,
        isAnswering: Bool,
        draft      : String
    ) -> BrowState {
        guard !isAnswering, !draft.allSatisfy(\.isWhitespace) else { return BrowState(status) }

        return .listening
    }

    /// Whether a change of the transcript's running turn is this worker's turn ending with its answer
    /// last, in the conversation the transcript shows. Opening another worker's conversation clears the
    /// turn of the one before it while its rows are still on screen; that is not a turn ending here.
    static func landsReply(
        wasRunning   : Bool,
        isRunning    : Bool,
        endsWithReply: Bool,
        isShown      : Bool
    ) -> Bool {
        isShown && wasRunning && !isRunning && endsWithReply
    }

    private static func isReply(_ kind: TranscriptItem.Kind?) -> Bool {
        if case .workerReply(_, false)? = kind { return true }
        return false
    }

    /// What the hero's body does through a turn: the
    /// reply landing, for one loop after the turn ends with it; otherwise, while the worker answers,
    /// replying once its answer has arrived, working once its tools have a step, reading the message
    /// just sent, then thinking until something comes. Nil outside a turn.
    static func action(
        isAnswering: Bool,
        isReading  : Bool,
        isLanding  : Bool,
        turn       : RunningTurn?
    ) -> WorkerAction? {
        if isLanding { return .replying }
        guard isAnswering else { return nil }
        if turn?.hasReplied == true { return .replying }
        if turn?.step != nil { return .working }
        return isReading ? .reading : .thinking
    }

    /// The worker as the house's rooms show it; an archived one, which has no room, as its own row.
    private var houseWorker: HouseWorker {
        HouseRoster.workers(of: team).first { $0.id == worker.id } ?? HouseRoster.worker(
            TeamRow(
                worker            : worker,
                isModelUnavailable: false,
                activity          : nil
            ),
            provider   : nil,
            isAnswering: team.isAnswering(worker.id),
            usesScreen : team.hasScreen(worker.id)
        )
    }

    // MARK: Transcript

    private var transcriptArea: some View {
        Group {
            if let transcript {
                TranscriptHost(
                    controller : transcript,
                    topInset   : 8,
                    bottomInset: composerHeight
                )
            } else {
                Color.clear
            }
        }
        .overlay {
            if transcript?.isEmpty ?? true { noMessages }
        }
        .opacity(isArriving ? 0 : 1)
        .overlay {
            if let still {
                ZStack {
                    if let image = still.image { HouseTranscriptStill(image: image) }
                    if still.isEmpty { noMessages }
                }
                .opacity(isArriving ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        // Hidden at once, revealed over the cross-fade; under Reduce Motion too, since it only fades.
        .animation(
            isArriving ? nil : .easeInOut(duration: HouseSwitch.crossFade),
            value: isArriving
        )
        // The transcript fades out under the hero rather than ending on an edge.
        .mask {
            LinearGradient(
                stops     : [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                ],
                startPoint: .top,
                endPoint  : .bottom
            )
        }
        .task(id: team.conversation?.id) { openTranscript() }
        .onChange(of: team.transcriptRevision) { transcript?.refresh() }
    }

    private var noMessages: some View {
        ContentUnavailableView(
            "No Messages Yet",
            systemImage: "bubble.left.and.bubble.right",
            description: Text(
                "Messages are saved in this conversation and remain available after you reopen Braus."
            )
        )
    }

    /// Opens the conversation at the position it was left at, or at the end, and reports the
    /// reading position as it changes.
    private func openTranscript() {
        guard let conversation = team.conversation else { return }

        let controller = transcript ?? TranscriptController(source: team.transcriptSource)
        transcript = controller

        let conversationID = conversation.id
        controller.onReadingPositionChange = { [team] anchor, offset in
            // A report that rests after a switch belongs to the conversation it was read in.
            guard team.conversation?.id == conversationID else { return }

            Task {
                await team.rememberReadingPosition(
                    anchor,
                    offset: offset
                )
            }
        }
        flights.attach(
            controller,
            to: conversationID
        )
        let focus = $composerFocus
        controller.onReply = { [team, flights] quote in
            flights.reply(
                quote,
                in: team
            )
            focus.wrappedValue += 1
        }
        controller.open(
            conversationID,
            workerName    : worker.name,
            workerProvider: worker.configuration?.provider,
            appearance    : worker.appearance,
            readingAnchor : conversation.readingAnchorMessageID,
            readingOffset : conversation.readingOffset
        )
    }
}
