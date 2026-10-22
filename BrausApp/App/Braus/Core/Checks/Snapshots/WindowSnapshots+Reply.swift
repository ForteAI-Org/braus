//
//  WindowSnapshots+Reply.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import ChatCore
import Foundation
import ModelTransports
import SeatBroker
import SwiftUI

extension WindowSnapshots {

    /// Replies and the queue: the window with a reply in
    /// progress on the composer, quoting Atlas and then the person, over a
    /// transcript that holds a bubble quoting each; the composer alone with each
    /// strip; then, while Atlas answers, the composer with one queued message,
    /// with three and the pager, and with a queued message over a reply.
    static func writeReply(to output: URL) async throws {
        let directory = URL.temporaryDirectory.appending(
            path         : "BrausReplySnapshots-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let (team, quotes) = try await replyTeam(in: directory)
        guard let worker = team.selectedWorker else { return }

        for (quoted, quote) in [("worker", quotes.worker), ("person", quotes.person)] {
            team.draftQuote = quote
            try await writeHouseWindow(
                team,
                width    : 1200,
                inspector: false,
                to       : output.appending(path: "house-reply-\(quoted).png")
            )
            try await write(
                composer(
                    of    : team,
                    worker: worker
                ),
                width : 560,
                height: 150,
                to    : output.appending(path: "composer-reply-\(quoted).png")
            )
        }
        team.draftQuote = nil

        try await writeQueue(
            of     : team,
            quoting: quotes.worker,
            to     : output
        )
        await team.closeAgentHosts()
    }

    /// The queue's scenes. Atlas's stand-in agent answers nothing and never
    /// ends, so the circle stays Stop and every send joins the queue.
    private static func writeQueue(
        of team      : TeamModel,
        quoting quote: MessageQuote,
        to output    : URL
    ) async throws {
        guard let worker = team.selectedWorker else { return }

        func queue(_ text: String) async {
            team.draft = text
            await team.send()
        }

        func write(_ scene: String) async throws {
            try await WindowSnapshots.write(
                composer(
                    of    : team,
                    worker: worker
                ),
                width : 560,
                height: 150,
                to    : output.appending(path: "composer-queue-\(scene).png")
            )
        }

        await queue("And the layout suite, can you rerun it?")
        for _ in 0..<100 where !team.isAnswering(worker.id) {
            try await Task.sleep(for: .milliseconds(20))
        }
        struct AtlasNeverAnswered: Error {}
        guard team.isAnswering(worker.id) else { throw AtlasNeverAnswered() }

        await queue("Then check yesterday’s build the same way.")
        try await write("one")

        await queue("If both fail, open an issue with the logs.")
        await queue("Thanks!")
        team.showNextQueued()
        try await write("three")

        team.draftQuote = quote
        team.draft      = "Is that the width assertion?"
        try await write("reply")
        try await writeHouseWindow(
            team,
            width    : 1200,
            inspector: false,
            to       : output.appending(path: "house-queue-reply.png")
        )
        team.draftQuote = nil
        team.draft      = ""
    }

    /// Atlas's conversation with two replies in it, one quoting Atlas's report
    /// and one quoting the person's own question, a turn's usage for the context
    /// ring, and the two quotes a draft can carry: Atlas's last answer, and the
    /// person's first question.
    private static func replyTeam(in directory: URL) async throws
        -> (team: TeamModel, quotes: (worker: MessageQuote, person: MessageQuote)) {
        let store = try WorkspaceStore.opening(in: directory)
        let atlas = try await store.createWorker(
            name      : "Atlas",
            role      : "Release engineer",
            appearance: WorkerAppearance(
                seed   : 7,
                palette: "tide"
            )
        )
        try await store.createWorker(
            name      : "Iris",
            role      : "Research lead",
            appearance: WorkerAppearance(
                seed   : 11,
                palette: "dusk"
            )
        )
        try await store.configure(
            worker   : atlas.id,
            selection: ModelSelection(
                provider: .codex,
                model   : "gpt-5.6-luna",
                effort  : .high
            )
        )
        let conversation = try await store.createConversation(
            kind        : .direct,
            participants: [atlas.id]
        ).id
        let origin = Date(timeIntervalSinceReferenceDate: 780_000_000)

        func say(
            _ text    : String,
            by author : UUID? = nil,
            at seconds: Double,
            quoting   : MessageSnapshot? = nil
        ) async throws -> MessageSnapshot {
            try await store.appendMessage(
                to      : conversation,
                author  : author,
                text    : text,
                at      : origin.addingTimeInterval(seconds),
                delivery: .completed,
                quote   : quoting.map(quote(of:))
            )
        }

        let question = try await say(
            "Can you check this morning’s build and tell me what failed?",
            at: 0
        )
        let report   = try await say(
            "The build finished at 07:42. Two bundles failed: the capture suite timed out once on the virtual "
                + "display, and the layout suite failed on a width assertion that reproduces locally.",
            by: atlas.id,
            at: 20
        )
        _ = try await say(
            "Which one should I look at first?",
            at     : 60,
            quoting: report
        )
        let answer   = try await say(
            "The width assertion. The capture timeout is flaky and passes on a rerun.",
            by: atlas.id,
            at: 80
        )
        _ = try await say(
            "Yesterday’s build too, please.",
            at     : 400,
            quoting: question
        )

        // A stand-in command line that answers nothing until it is stopped, for the queue's scenes.
        let agent = directory.appending(path: "agent")
        try Data("#!/bin/sh\nexec sleep 600\n".utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path(percentEncoded: false)
        )
        let team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent
        )
        await team.load()
        team.selection = atlas.id
        await team.openSelectedConversation()
        return (team, (quote(of: answer), quote(of: question)))
    }

    /// `worker`'s composer alone at the foot of the conversation's ground, as the window shows it.
    static func composer(
        of team: TeamModel,
        worker : WorkerSnapshot
    ) -> some View {
        ConversationComposer(
            team  : team,
            worker: worker,
            height: .constant(0)
        )
        .frame(
            maxHeight: .infinity,
            alignment: .bottom
        )
        .background(Color("HouseGround"))
    }

    /// The whole of `message`, as a reply from its menu quotes it.
    private static func quote(of message: MessageSnapshot) -> MessageQuote {
        MessageQuote(
            messageID     : message.id,
            authorWorkerID: message.authorWorkerID,
            text          : message.text
        )
    }
}
