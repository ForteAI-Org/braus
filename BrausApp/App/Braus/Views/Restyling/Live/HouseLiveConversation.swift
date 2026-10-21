//
//  HouseLiveConversation.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import ModelTransports
import SwiftUI

/// HouseLiveConversation is a worker's conversation in the new look (`AppPreferences.newLook`): the
/// worker standing at the top (`HouseHero`) over the app's own transcript (`TranscriptHost` and
/// `TranscriptController`, as `WorkerConversationView` hosts them), and the app's composer floating
/// over the transcript's foot in the new look's chrome (`ConversationComposer`, `ComposerBar.Chrome`).
///
/// The hero reads the team: its light is the worker's status as the house's rooms show it
/// (`HouseRoster`), its subtitle what the worker is doing (the desktop's activity, or "Working") or
/// its role; it listens while the person writes to it between turns, and sets about a message each
/// time a turn starts. Another worker hops out of the capsule in its place. The transcript and the
/// composer keep every behaviour of today's conversation: windows of history, reading position,
/// replies, the queue, slash commands, the model popup, Stop and Release. Messages fly across it
/// (`HouseLiveFlights`): a sent one into its bubble, a queued one into and out of the queue strip,
/// a quote into the reply strip and back.
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

    /// The flights of sent, queued and quoted messages over the conversation.
    @State private var flights = HouseLiveFlights()

    var body: some View {
        let house       = houseWorker
        let isAnswering = team.isAnswering(worker.id)
        VStack(spacing: 0) {
            HouseHero(
                worker     : house,
                status     : house.status,
                brows      : Self.brows(
                    status     : house.status,
                    isAnswering: isAnswering,
                    draft      : team.draft
                ),
                activity   : house.subtitle,
                preparation: preparation
            )
            .onChange(of: isAnswering) { was, now in
                if now, !was { preparation += 1 }
            }
            // Each worker hops out of the capsule as it arrives, its edge of `isAnswering` its own.
            .id(worker.id)
            .padding(
                .top,
                6
            )
            transcriptArea
                .overlay(alignment: .bottom) {
                    ConversationComposer(
                        team        : team,
                        worker      : worker,
                        height      : $composerHeight,
                        focusRequest: composerFocus + focusRequest,
                        reveal      : { transcript?.revealQuoted($0) },
                        chrome      : .house,
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
        .task(id: team.conversation?.id) { openTranscript() }
        .onChange(of: team.transcriptRevision) { transcript?.refresh() }
        .overlay {
            if transcript?.isEmpty ?? true {
                ContentUnavailableView(
                    "No Messages Yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(
                        "Messages are saved in this conversation and remain available after you reopen Braus."
                    )
                )
            }
        }
    }

    /// Opens the conversation at the position it was left at, or at the end, as
    /// `WorkerConversationView` does.
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
