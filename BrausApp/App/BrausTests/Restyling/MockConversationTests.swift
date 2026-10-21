//
//  MockConversationTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Testing
@testable import Braus

@Suite("MockConversation")
@MainActor
struct MockConversationTests {

    @Test("What is sent during a turn waits in the queue")
    func sendingDuringATurnQueues() throws {
        let conversation = MockConversation(workerName: "Delivery")
        let first        = try #require(conversation.send("Export the stems."))
        #expect(first.author == .person)
        #expect(conversation.isAnswering)
        #expect(conversation.send("And zip them.") == nil)
        #expect(conversation.queue.items == ["And zip them."])
        #expect(conversation.messages.last?.id == first.id)
    }

    @Test("Send Now stops the turn and sends the shown message")
    func sendNowStopsTheTurn() throws {
        let conversation = MockConversation(workerName: "Delivery")
        conversation.send("Export the stems.")
        conversation.send("One.")
        conversation.send("Two.")
        conversation.queue.page = 0
        let sent = try #require(conversation.sendNow())
        #expect(sent.text == "One.")
        #expect(conversation.isAnswering)
        #expect(conversation.queue.items == ["Two."])
        #expect(!conversation.messages.contains { $0.isThinking })
    }

    @Test("At the end of a turn the shown queued message goes, and only then")
    func endOfTurnSendsTheShown() throws {
        let conversation = MockConversation(workerName: "Delivery")
        conversation.send("Export the stems.")
        conversation.send("One.")
        conversation.send("Two.")
        conversation.queue.page = 1
        #expect(conversation.sendQueued() == nil)
        conversation.stopTurn()
        let sent = try #require(conversation.sendQueued())
        #expect(sent.text == "Two.")
        #expect(conversation.queue.items == ["One."])
    }

    @Test("A reply carries its quote, with the worker's name before the worker's words")
    func replyCarriesTheQuote() throws {
        let conversation = MockConversation(workerName: "Delivery")
        let worker       = try #require(conversation.messages.last { $0.author == .worker })
        conversation.quote = worker
        let reply = try #require(conversation.send("Stereo interleaved."))
        #expect(reply.quote == "Delivery: \(worker.text)")
        #expect(conversation.quote == nil)
    }
}
