//
//  MessageQueueTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Testing
@testable import Braus

@Suite("MessageQueue")
struct MessageQueueTests {

    @Test("Adding pages to the newest message")
    func addPagesToTheNewest() {
        var queue = MessageQueue()
        queue.add("One")
        queue.add("Two")
        queue.add("Three")
        #expect(queue.items == ["One", "Two", "Three"])
        #expect(queue.page == 2)
    }

    @Test("Send Now takes the paged message out")
    func sendNowTakesThePagedMessage() {
        var queue = MessageQueue()
        queue.add("One")
        queue.add("Two")
        queue.add("Three")
        queue.page = 1
        #expect(queue.sendNow() == "Two")
        #expect(queue.items == ["One", "Three"])
        #expect(queue.items.indices.contains(queue.page))
    }

    @Test("Dropping removes the paged message and keeps the page in range")
    func dropKeepsThePageInRange() {
        var queue = MessageQueue()
        queue.add("One")
        queue.add("Two")
        queue.add("Three")
        queue.drop()
        #expect(queue.items == ["One", "Two"])
        #expect(queue.items.indices.contains(queue.page))
        queue.page = 0
        queue.drop()
        #expect(queue.items == ["Two"])
        #expect(queue.page == 0)
        queue.drop()
        #expect(queue.items.isEmpty)
        #expect(queue.page == 0)
    }

    @Test("The end of a turn takes the first message out")
    func endOfTurnTakesTheFirst() {
        var queue = MessageQueue()
        queue.add("One")
        queue.add("Two")
        queue.add("Three")
        #expect(queue.endOfTurn() == "One")
        #expect(queue.items == ["Two", "Three"])
        #expect(queue.items.indices.contains(queue.page))
    }

    @Test("An empty queue gives nothing")
    func emptyQueueGivesNothing() {
        var queue = MessageQueue()
        #expect(queue.sendNow() == nil)
        #expect(queue.endOfTurn() == nil)
        queue.drop()
        #expect(queue.items.isEmpty)
    }
}
