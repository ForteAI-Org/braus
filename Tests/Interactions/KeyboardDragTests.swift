//
//  KeyboardDragTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import CoreGraphics
import Foundation
@testable import InteractionListener
import Synchronization
import Testing

/// Exercises passive classification without installing a tap or posting input to an application.
@Suite
struct KeyboardDragTests {
    private func context(buttons: InteractionButtonState = InteractionButtonState()) -> TapContext {
        let pair = AsyncThrowingStream<InteractionEvent, any Error>.makeStream()
        let context = TapContext(buttons: buttons, continuation: pair.continuation, hover: false, excludedPID: -1)
        context.snapshot.withLock {
            $0 = AttributionSnapshot(generation: 7, windows: [
                InteractionWindow(processID: 42, number: 101, title: nil, layer: 0,
                                  frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
                InteractionWindow(processID: 43, number: 102, title: nil, layer: 0,
                                  frame: CGRect(x: 200, y: 0, width: 200, height: 200)),
            ])
        }
        return context
    }

    private func key(
        _ code: CGKeyCode = 0, flags: CGEventFlags = [], target: Int64 = 42, text: String = ""
    ) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
        event.flags = flags
        event.location = CGPoint(x: 300, y: 100)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 99)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: target)
        let characters = Array(text.utf16)
        characters.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
        return event
    }

    private func pointer(
        _ type: CGEventType, x: Double = 10, y: Double = 20, target: Int64 = 42, window: Int64 = 101
    ) throws -> CGEvent {
        let event = try #require(CGEvent(source: nil))
        event.type = type
        event.location = CGPoint(x: x, y: y)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 99)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: target)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: window)
        return event
    }

    private func drain(_ context: TapContext) -> [InputRecord] {
        var records: [InputRecord] = []
        while let record = context.queue.pop() { records.append(record) }
        return records
    }

    @Test func doubleClicksCarryTheirCountWithoutChangingTheWireLayout() throws {
        let context = context()
        let down = try pointer(.leftMouseDown)
        down.setIntegerValueField(.mouseEventClickState, value: 2)
        context.receive(type: .leftMouseDown, event: down)
        let event = try #require(drain(context).first.flatMap { InteractionEvent(record: $0, title: nil) })
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        #expect(json["clickCount"] as? Int == 2)
        #expect(MemoryLayout<InputRecord>.stride == 104)
    }

    @Test func mixedInputPreservesGestureOrderAndFields() throws {
        let context = context()
        context.receive(type: .leftMouseDown, event: try pointer(.leftMouseDown))
        context.receive(type: .leftMouseUp, event: try pointer(.leftMouseUp))
        for text in ["a", "b", "c"] { context.receive(type: .keyDown, event: try key(text: text)) }
        context.receive(type: .keyDown, event: try key(1, flags: .maskCommand))
        context.receive(type: .keyDown, event: try key(36))
        context.receive(type: .leftMouseDown, event: try pointer(.leftMouseDown))
        context.receive(type: .leftMouseDragged, event: try pointer(.leftMouseDragged, x: 30, y: 40))
        context.receive(type: .leftMouseUp, event: try pointer(.leftMouseUp, x: 250, y: 60, target: 43, window: 102))
        let scroll = try pointer(.scrollWheel)
        scroll.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 12)
        context.receive(type: .scrollWheel, event: scroll)
        context.receive(type: .rightMouseDown, event: try pointer(.rightMouseDown))
        let events = drain(context).compactMap { InteractionEvent(record: $0, title: nil) }
        #expect(events.map(\.kind.rawValue) == ["click", "typing", "shortcut", "shortcut", "click", "drag", "scroll", "rightClick"])
        #expect(events.map(\.sequence) == Array(1...8))
        try #require(events.count == 8)
        let typing = try #require(events.first { $0.kind.rawValue == "typing" })
        #expect(typing.processID == 42 && typing.window?.number == 101)
        #expect(typing.startedAt <= typing.endedAt)
        #expect(typing.keyCode == nil && typing.modifiers == nil && typing.endPoint == nil)
        #expect(events[2].keyCode == 1 && events[2].modifiers == .command)
        #expect(events[3].keyCode == 36 && events[3].modifiers == [])
        let drag = try #require(events.first { $0.kind.rawValue == "drag" })
        #expect(drag.point == CGPoint(x: 10, y: 20))
        #expect(drag.processID == 42 && drag.window?.number == 101)
        #expect(drag.startedAt < drag.endedAt)
        #expect(drag.endPoint == CGPoint(x: 250, y: 60))
        #expect(drag.deltaX == 0 && drag.deltaY == 0)
        #expect(events.first { $0.kind == .scroll }?.deltaY == 12)
    }

    @Test func typingSplitsOnTargetChangeAndOtherInput() throws {
        let context = context()
        for _ in 0..<3 { context.receive(type: .keyDown, event: try key()) }
        #expect(drain(context).isEmpty)
        context.receive(type: .keyDown, event: try key(target: 43))
        let first = drain(context)
        #expect(first.map(\.kind) == [.typing])
        #expect(first.first?.targetPID == 42)
        context.receive(type: .mouseMoved, event: try pointer(.mouseMoved))
        #expect(drain(context).map(\.targetPID) == [43])
        context.receive(type: .keyDown, event: try key())
        context.receive(type: .rightMouseDown, event: try pointer(.rightMouseDown))
        #expect(drain(context).map(\.kind) == [.typing, .rightClick])
    }

    @Test func onlyDragReleaseAdvancesRevision() throws {
        let buttons = InteractionButtonState()
        let context = context(buttons: buttons)
        context.receive(type: .leftMouseDown, event: try pointer(.leftMouseDown))
        let click = try #require(drain(context).first)
        #expect(buttons.snapshot().processID == 42)
        context.receive(type: .leftMouseUp, event: try pointer(.leftMouseUp))
        #expect(buttons.snapshot().processID == nil)
        #expect(context.revision == click.revision)
        #expect(drain(context).isEmpty)

        context.receive(type: .leftMouseDown, event: try pointer(.leftMouseDown))
        let dragClick = try #require(drain(context).first)
        context.receive(type: .leftMouseDragged, event: try pointer(.leftMouseDragged, x: 30))
        let movementRevision = context.revision
        #expect(movementRevision > dragClick.revision)
        context.receive(type: .leftMouseUp, event: try pointer(.leftMouseUp, x: 30))
        let records = drain(context)
        #expect(context.revision > movementRevision)
        #expect(records.map(\.kind) == [.drag])
        #expect(records.first?.revision == context.revision)
    }

    @Test func releaseRequiresMovementBeyondThreePoints() throws {
        let context = context()
        for distance in [0.0, 3.0, 3.01] {
            context.receive(type: .leftMouseDown, event: try pointer(.leftMouseDown))
            context.receive(type: .leftMouseDragged, event: try pointer(.leftMouseDragged, x: 10 + distance))
            context.receive(type: .leftMouseUp, event: try pointer(.leftMouseUp))
            let events = drain(context).compactMap { InteractionEvent(record: $0, title: nil) }
            #expect(events.map(\.kind.rawValue) == (distance > 3 ? ["click", "drag"] : ["click"]))
        }
        context.receive(type: .leftMouseDragged, event: try pointer(.leftMouseDragged, x: 100))
        context.receive(type: .leftMouseUp, event: try pointer(.leftMouseUp))
        #expect(drain(context).isEmpty)
    }

    @Test func unicodePayloadNeverReachesRecordsEventsOrJSON() throws {
        let context = context()
        let secret = "密碼雪狐"
        for character in secret {
            context.receive(type: .keyDown, event: try key(flags: [.maskShift, .maskAlternate], text: String(character)))
        }
        context.receive(type: .keyDown, event: try key(1, flags: .maskCommand, text: secret))
        let records = drain(context)
        let events = records.compactMap { InteractionEvent(record: $0, title: secret) }
        #expect(events.map(\.kind.rawValue) == ["typing", "shortcut"])
        let data = try JSONEncoder().encode(events)
        let json = String(decoding: data, as: UTF8.self)
        #expect(try JSONDecoder().decode([InteractionEvent].self, from: data) == events)
        #expect(events.allSatisfy { $0.window?.title == nil })
        for character in secret {
            #expect(!String(describing: records).contains(character))
            #expect(!String(describing: events).contains(character))
            #expect(!json.contains(character))
        }
        let typing = try #require(records.first)
        #expect(typing.lostCritical == 0 && typing.lostCoalescible == 0)
        #expect(typing.valueA == 0 && typing.valueB == 0)
        #expect(typing.revision - typing.precedingRevision != UInt64(secret.count))
        #expect(context.latency.input.count == 0 && context.latency.pointer.count == 0)
    }

    @Test func nonTextKeysAndCommandModifiersProduceShortcuts() throws {
        let context = context()
        let codes: [CGKeyCode] = [
            36, 48, 53, 71, 76, 114, 115, 116, 119, 121, 123, 124, 125, 126,
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        ]
        for code in codes {
            context.receive(type: .keyDown, event: try key(code))
            context.receive(type: .keyDown, event: try key(code, flags: [.maskAlternate, .maskShift]))
        }
        let events = drain(context).compactMap { InteractionEvent(record: $0, title: nil) }
        try #require(events.count == codes.count * 2)
        for (index, code) in codes.enumerated() {
            #expect(events[index * 2].kind == .shortcut && events[index * 2].keyCode == code)
            #expect(events[index * 2].modifiers == [])
            #expect(events[index * 2 + 1].modifiers == [.option, .shift])
        }
        context.receive(type: .keyDown, event: try key(0, flags: [.maskControl, .maskAlphaShift]))
        context.receive(type: .keyDown, event: try key(1, flags: [.maskCommand, .maskControl, .maskAlternate, .maskShift]))
        let modified = drain(context).compactMap { InteractionEvent(record: $0, title: nil) }
        #expect(modified.map(\.kind) == [.shortcut, .shortcut])
        try #require(modified.count == 2)
        #expect(modified[0].modifiers == .control)
        #expect(modified[1].modifiers == [.command, .control, .option, .shift])
    }

    @Test func editingKeysJoinTypingUnlessCommandOrControlIsHeld() throws {
        for code: CGKeyCode in [51, 117] {
            for flags: CGEventFlags in [[], .maskAlternate, .maskShift] {
                let context = context()
                context.receive(type: .keyDown, event: try key())
                context.receive(type: .keyDown, event: try key(code, flags: flags))
                context.receive(type: .keyDown, event: try key(1))
                context.receive(type: .mouseMoved, event: try pointer(.mouseMoved))
                #expect(drain(context).map(\.kind) == [.typing])
            }
            for flags: CGEventFlags in [.maskCommand, .maskControl] {
                let context = context()
                context.receive(type: .keyDown, event: try key(code, flags: flags))
                #expect(drain(context).map(\.kind) == [.shortcut])
            }
        }
    }

    @Test func autorepeatKeepsOneShortcutPerPressAndExtendsTyping() throws {
        let context = context()
        for code: CGKeyCode in [1, 123] {
            let event = try key(code, flags: code == 1 ? .maskCommand : [])
            context.receive(type: .keyDown, event: event)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            for _ in 0..<20 { context.receive(type: .keyDown, event: event) }
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            context.receive(type: .keyDown, event: event)
            #expect(drain(context).map(\.kind) == [.shortcut, .shortcut])
        }
        for code: CGKeyCode in [0, 51, 117] {
            let event = try key(code)
            context.receive(type: .keyDown, event: event)
            let initialRevision = context.revision
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            for _ in 0..<20 { context.receive(type: .keyDown, event: event) }
            let lastRevision = context.revision
            #expect(drain(context).isEmpty)
            context.receive(type: .mouseMoved, event: try pointer(.mouseMoved))
            let records = drain(context)
            #expect(records.map(\.kind) == [.typing])
            #expect(records.first?.revision == lastRevision)
            #expect(lastRevision > initialRevision)
            #expect(records.first.map { $0.timestamp > $0.startTimestamp } == true)
        }
    }

    @Test func typingSettlesThroughTheExistingWakeTimer() throws {
        let context = context()
        let timer = try #require(context.addWakeTimer(to: CFRunLoopGetCurrent()))
        defer { CFRunLoopTimerInvalidate(timer) }
        context.receive(type: .keyDown, event: try key())
        context.receive(type: .keyDown, event: try key(1))
        #expect(drain(context).isEmpty)
        CFRunLoopRunInMode(.defaultMode, 2.2, false)
        let records = drain(context)
        #expect(records.map(\.kind) == [.typing])
        #expect(records.first?.targetPID == 42)
        context.receive(type: .keyDown, event: try key())
        context.receive(type: .keyDown, event: try key(36))
        #expect(drain(context).map(\.kind) == [.typing, .shortcut])
    }

    @Test func typingQuietBoundarySplitsEvenBeforeTimerDelivery() throws {
        var typing = TypingGesture()
        func record(_ at: UInt64) -> InputRecord {
            var record = InputRecord(kind: .typing, timestamp: at, precedingRevision: at - 1, revision: at)
            record.targetPID = 42
            return record
        }
        #expect(typing.deadline == nil)
        #expect(typing.append(record(1_000_000_000)) == nil)
        #expect(typing.append(record(2_000_000_000)) == nil)
        #expect(typing.deadline == 4.0)
        #expect(typing.settled(at: 3.999) == nil)
        let flushed = typing.append(record(4_000_000_000))
        let first = try #require(flushed)
        #expect(first.startTimestamp == 1_000_000_000 && first.timestamp == 2_000_000_000)
        #expect(typing.settled(at: 6.0)?.startTimestamp == 4_000_000_000)
        #expect(typing.deadline == nil && typing.take() == nil)
    }

    @Test func newCriticalKindsUseReservedCapacityAndReportOverflow() {
        let queue = InputQueue(capacity: 8, reserved: 4)
        for _ in 0..<5 { queue.push(InputRecord(kind: .hover, timestamp: 1, precedingRevision: 0, revision: 1)) }
        for kind: InputRecord.Kind in [.shortcut, .typing, .drag, .shortcut, .drag] {
            queue.push(InputRecord(kind: kind, timestamp: 2, precedingRevision: 1, revision: 2))
        }
        var records: [InputRecord] = []
        while let record = queue.pop() { records.append(record) }
        #expect(records.map(\.kind) == [.hover, .hover, .hover, .hover, .shortcut, .typing, .drag, .shortcut])
        queue.retry()
        #expect(queue.pop()?.lostCritical == 1)
        #expect(queue.counters.lostCritical == 1 && queue.counters.lostCoalescible == 0)
    }

    @Test func excludesKeysPostedByThisProcess() throws {
        let context = context()
        let event = try key(1, flags: .maskCommand)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: -1)
        context.receive(type: .keyDown, event: event)
        #expect(drain(context).isEmpty)
        #expect(context.revision == 0)
    }
}
