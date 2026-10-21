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

    @Test("Adding keeps the strip on the message that goes next, the oldest at first")
    func addKeepsTheNextShown() {
        var queue = MessageQueue()
        queue.add("One")
        queue.add("Two")
        queue.add("Three")
        #expect(queue.items == ["One", "Two", "Three"])
        #expect(queue.page == 0)
        queue.page = 2
        queue.add("Four")
        #expect(queue.page == 2)
    }

    @Test("The end of a turn takes out the shown message, then shows the oldest")
    func endOfTurnTakesTheShown() {
        var queue = MessageQueue()
        queue.add("One")
        queue.add("Two")
        queue.add("Three")
        #expect(queue.endOfTurn() == "One")
        #expect(queue.items == ["Two", "Three"])
        queue.page = 1
        #expect(queue.endOfTurn() == "Three")
        #expect(queue.items == ["Two"])
        #expect(queue.page == 0)
    }

    @Test("Send Now takes out the shown message, then shows the oldest")
    func sendNowTakesTheShown() {
        var queue = MessageQueue()
        queue.add("One")
        queue.add("Two")
        queue.add("Three")
        queue.page = 1
        #expect(queue.sendNow() == "Two")
        #expect(queue.items == ["One", "Three"])
        #expect(queue.page == 0)
    }

    @Test("Dropping removes the shown message and keeps the page in range")
    func dropKeepsThePageInRange() {
        var queue = MessageQueue()
        queue.add("One")
        queue.add("Two")
        queue.add("Three")
        queue.page = 2
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

    @Test("An empty queue gives nothing")
    func emptyQueueGivesNothing() {
        var queue = MessageQueue()
        #expect(queue.sendNow() == nil)
        #expect(queue.endOfTurn() == nil)
        queue.drop()
        #expect(queue.items.isEmpty)
    }
}
