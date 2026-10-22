//
//  WorkspaceMigrationTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import ModelTransports
import SwiftData
import Testing
@testable import Braus

/// WorkspaceMigrationTests opens stores written before replies (`StoreShapeV4`),
/// the queue (`StoreShapeV5`) and worker shapes (`StoreShapeV6`) with
/// the app's one schema through `WorkspaceStore.opening(in:)`, with no
/// migration plan.
@Suite("Upgrading older stores")
struct WorkspaceMigrationTests {

    @Test("An unrecognized stored shape uses the identity default without rewriting the value")
    func unknownShapeUsesDefault() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let store = try WorkspaceStore.opening(in: directory)
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let worker = try await store.createWorker(
            id        : id,
            name      : "Atlas",
            appearance: TemporaryStore.appearance(),
            shape     : "future-outline"
        )
        #expect(worker.shape == .square)
        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.worker(id)?.shape == .square)
        let context = ModelContext(try WorkspaceStoreFile.open(in: directory))
        #expect(try context.fetch(FetchDescriptor<Worker>()).first?.shape == "future-outline")
    }

    @Test("A pre-shape store keeps every entity, derives shapes, and persists edits after reopening")
    func aStoreFromBeforeShapesOpens() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let atlas = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let nova = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let conversationID = UUID()
        let messageID = UUID()
        let executionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let quote = MessageQuote(
            messageID     : messageID,
            authorWorkerID: atlas,
            text          : "Checked"
        )
        let queue = [QueuedMessage(
            text : "Next release",
            quote: quote
        )]
        try writeStore(
            in: directory,
            as: StoreShapeV6.self
        ) { context in
            context.insert(StoreShapeV6.Worker(
                id          : atlas,
                name        : "Atlas",
                role        : "Engineer",
                instructions: "Check releases",
                createdAt   : createdAt,
                appearance  : TemporaryStore.appearance()
            ))
            context.insert(StoreShapeV6.Worker(
                id        : nova,
                name      : "Nova",
                isArchived: true,
                appearance: TemporaryStore.appearance(palette: "dawn")
            ))
            for version in 1...2 {
                context.insert(WorkerConfiguration(
                    workerID : atlas,
                    version  : version,
                    selection: version == 1 ? TemporaryStore.firstSelection : TemporaryStore.secondSelection
                ))
            }
            let conversation = Conversation(
                id            : conversationID,
                participantIDs: [atlas],
                draft         : "Half a reply"
            )
            conversation.queuedMessages           = try JSONEncoder().encode(queue)
            conversation.draftQuoteMessageID      = quote.messageID
            conversation.draftQuoteAuthorWorkerID = quote.authorWorkerID
            conversation.draftQuoteText           = quote.text
            context.insert(conversation)
            context.insert(Message(
                id            : messageID,
                conversationID: conversationID,
                authorWorkerID: atlas,
                text          : "Checked",
                sequence      : 1,
                delivery      : .completed,
                quote         : quote
            ))
            context.insert(Execution(
                id                  : executionID,
                workerID            : atlas,
                conversationID      : conversationID,
                configurationVersion: 1,
                selection           : TemporaryStore.firstSelection
            ))
            context.insert(WorkspaceEvent(
                NewEvent(
                    workspaceID   : UUID(),
                    subjectID     : executionID,
                    conversationID: conversationID,
                    workerID      : atlas,
                    type          : .executionFailed
                ),
                localOrder: 1
            ))
        }
        let file = directory.appending(path: WorkspaceStoreFile.storeName)
        #expect(WorkspaceStoreFile.isUpgradeDue(file))
        let existingSuffixes = WorkspaceStoreFile.fileSuffixes.filter { suffix in
            let source = directory.appending(path: WorkspaceStoreFile.storeName + suffix)
            return FileManager.default.fileExists(atPath: source.path(percentEncoded: false))
        }
        let upgraded = try WorkspaceStore.opening(in: directory)
        #expect(!WorkspaceStoreFile.isUpgradeDue(file))
        for suffix in existingSuffixes {
            let backup = directory.appending(
                path: WorkspaceStoreFile.storeName + suffix + WorkspaceStoreFile.backupSuffix
            )
            #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
        }

        let workers = try await upgraded.workers(includingArchived: true)
        #expect(workers.map(\.id) == [atlas, nova])
        let worker = try #require(workers.first)
        #expect(worker.name == "Atlas")
        #expect(worker.role == "Engineer")
        #expect(worker.instructions == "Check releases")
        #expect(worker.createdAt == createdAt)
        #expect(worker.appearance == TemporaryStore.appearance())
        #expect(worker.configurationVersion == 2)
        #expect(worker.configuration == TemporaryStore.secondSelection)
        #expect(worker.shape == .circle)
        #expect(workers.last?.shape == .square)
        #expect(workers.last?.isArchived == true)
        #expect(workers.last?.appearance == TemporaryStore.appearance(palette: "dawn"))
        let conversation = try #require(try await upgraded.conversation(conversationID))
        #expect(conversation.draft == "Half a reply")
        #expect(conversation.participantIDs == [atlas])
        #expect(conversation.draftQuote == quote)
        #expect(conversation.queue == queue)
        let messages = try await upgraded.messages(in: conversationID)
        #expect(messages.map(\.id) == [messageID])
        #expect(messages.first?.text == "Checked")
        #expect(messages.first?.quote == quote)
        #expect(try await upgraded.execution(executionID)?.selection == TemporaryStore.firstSelection)
        #expect(try await upgraded.events(matching: EventQuery(scope: .conversation(conversationID))).count == 1)

        do {
            let context = ModelContext(try WorkspaceStoreFile.open(in: directory))
            let rows = try context.fetch(FetchDescriptor<Worker>())
            #expect(rows.allSatisfy { $0.shape == nil })
            #expect(try context.fetchCount(FetchDescriptor<WorkerConfiguration>()) == 2)
            #expect(try context.fetchCount(FetchDescriptor<Execution>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Conversation>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Message>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<WorkspaceEvent>()) == 1)
        }
        try await upgraded.update(
            worker: atlas,
            .shape("lens")
        )
        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.worker(atlas)?.shape == .lens)
        #expect(try await reopened.worker(nova)?.shape == .square)
        let context = ModelContext(try WorkspaceStoreFile.open(in: directory))
        #expect(try context.fetch(FetchDescriptor<Worker>()).first { $0.id == atlas }?.shape == "lens")
    }

    @Test("A store from before replies keeps every row, and reads no quote and an empty queue")
    func aStoreFromBeforeRepliesOpens() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let atlas          = UUID()
        let nova           = UUID()
        let conversationID = UUID()
        try writeStore(
            in: directory,
            as: StoreShapeV4.self
        ) { context in
            context.insert(StoreShapeV6.Worker(
                id        : atlas,
                name      : "Atlas",
                role      : "Release engineer",
                appearance: TemporaryStore.appearance()
            ))
            context.insert(StoreShapeV6.Worker(
                id        : nova,
                name      : "Nova",
                appearance: TemporaryStore.appearance(palette: "dawn")
            ))
            context.insert(WorkerConfiguration(
                workerID : atlas,
                version  : 1,
                selection: TemporaryStore.firstSelection
            ))
            context.insert(StoreShapeV4.Conversation(
                id            : conversationID,
                participantIDs: [atlas],
                draft         : "half a reply"
            ))
            context.insert(StoreShapeV4.Message(
                conversationID: conversationID,
                text          : "ask",
                sequence      : 1
            ))
            context.insert(StoreShapeV4.Message(
                conversationID: conversationID,
                authorWorkerID: atlas,
                text          : "answer",
                sequence      : 2
            ))
            context.insert(WorkspaceEvent(
                NewEvent(
                    workspaceID   : UUID(),
                    subjectID     : UUID(),
                    conversationID: conversationID,
                    workerID      : atlas,
                    type          : .executionFailed
                ),
                localOrder: 1
            ))
        }
        let file = directory.appending(path: WorkspaceStoreFile.storeName)
        #expect(WorkspaceStoreFile.isUpgradeDue(file))

        let upgraded = try WorkspaceStore.opening(in: directory)

        #expect(!WorkspaceStoreFile.isUpgradeDue(file))
        let backup = directory.appending(path: WorkspaceStoreFile.storeName + WorkspaceStoreFile.backupSuffix)
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))

        #expect(try await upgraded.workers().map(\.name) == ["Atlas", "Nova"])
        let worker = try #require(try await upgraded.worker(atlas))
        #expect(worker.role == "Release engineer")
        #expect(worker.appearance == TemporaryStore.appearance())
        #expect(worker.configuration == TemporaryStore.firstSelection)

        let conversation = try #require(try await upgraded.conversation(conversationID))
        #expect(conversation.draft == "half a reply")
        #expect(conversation.participantIDs == [atlas])
        #expect(conversation.resumableSession(for: .claudeCode) == "session-4")
        #expect(conversation.draftQuote == nil)
        #expect(conversation.queue.isEmpty)

        let messages = try await upgraded.messages(in: conversationID)
        #expect(messages.map(\.text) == ["ask", "answer"])
        #expect(messages.map(\.sequence) == [1, 2])
        #expect(messages.map(\.quote) == [nil, nil])
        #expect(messages.last?.authorWorkerID == atlas)
        #expect(try await upgraded.events(matching: EventQuery(scope: .conversation(conversationID))).count == 1)

        // The upgraded store takes the new columns, and keeps them across a reopen.
        let answer = try #require(messages.last)
        let quote  = MessageQuote(
            messageID     : answer.id,
            authorWorkerID: atlas,
            text          : "answer"
        )
        try await upgraded.update(
            conversation: conversationID,
            .draftQuote(quote)
        )
        try await upgraded.update(
            conversation: conversationID,
            .queue([QueuedMessage(text: "and then?")])
        )
        let reply = try await upgraded.appendMessage(
            to   : conversationID,
            text : "why?",
            quote: quote
        )
        #expect(reply.sequence == 3)

        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.conversation(conversationID)?.draftQuote == quote)
        #expect(try await reopened.conversation(conversationID)?.queue == [QueuedMessage(text: "and then?")])
        #expect(try await reopened.messages(in: conversationID).last?.quote == quote)
    }

    @Test("A store from the reply build keeps its quotes, and reads an empty queue")
    func aStoreFromTheReplyBuildOpens() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let atlas          = UUID()
        let conversationID = UUID()
        let answerID       = UUID()
        let quote          = MessageQuote(
            messageID     : answerID,
            authorWorkerID: atlas,
            text          : "Two bundles failed."
        )
        try writeStore(
            in: directory,
            as: StoreShapeV5.self
        ) { context in
            context.insert(StoreShapeV6.Worker(
                id        : atlas,
                name      : "Atlas",
                appearance: TemporaryStore.appearance()
            ))
            context.insert(StoreShapeV5.Conversation(
                id            : conversationID,
                participantIDs: [atlas],
                draft         : "which one",
                draftQuote    : quote
            ))
            context.insert(StoreShapeV5.Message(
                conversationID: conversationID,
                text          : "ask",
                sequence      : 1
            ))
            context.insert(StoreShapeV5.Message(
                id            : answerID,
                conversationID: conversationID,
                authorWorkerID: atlas,
                text          : "Two bundles failed.",
                sequence      : 2
            ))
            context.insert(StoreShapeV5.Message(
                conversationID: conversationID,
                text          : "why?",
                sequence      : 3,
                quote         : quote
            ))
        }
        let file = directory.appending(path: WorkspaceStoreFile.storeName)
        #expect(WorkspaceStoreFile.isUpgradeDue(file))

        let upgraded = try WorkspaceStore.opening(in: directory)

        #expect(!WorkspaceStoreFile.isUpgradeDue(file))
        let conversation = try #require(try await upgraded.conversation(conversationID))
        #expect(conversation.draft == "which one")
        #expect(conversation.draftQuote == quote)
        #expect(conversation.queue.isEmpty)

        let messages = try await upgraded.messages(in: conversationID)
        #expect(messages.map(\.text) == ["ask", "Two bundles failed.", "why?"])
        #expect(messages.map(\.quote) == [nil, nil, quote])
        #expect(try await upgraded.worker(atlas)?.name == "Atlas")

        try await upgraded.update(
            conversation: conversationID,
            .queue([QueuedMessage(
                text : "and the other?",
                quote: quote
            )])
        )
        #expect(try await upgraded.conversation(conversationID)?.queue.first?.quote == quote)
    }
}
