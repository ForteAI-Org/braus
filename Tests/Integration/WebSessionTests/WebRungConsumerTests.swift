//
//  WebRungConsumerTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing
import WebDriver
import WebDriving
import WebSession

/// M05, the web's rung through the actual consumer (W-R2): the production `WebAutomationSession`, pointed at "the
/// person's own Chrome" that is the synthetic page inside the process (`WebBrowser.attached` over it, as the
/// personal-Chrome tests do: no Chrome runs, nothing is connected to), under `AutomationTools` and `memory_task`. A
/// click records its rung under the task, a text typed into a password field records its keys' counts and none of the
/// text anywhere, a click the page would deliver to a banner records none; the session leaves the page as it found it
/// but for the tab it opened and closed. The default composition (Braus's own Chrome) is untouched: the launch options
/// name no Chrome, and nothing launches.
@MainActor
@Suite("M05: the web session's calls record their rung through the tools", .serialized)
struct WebRungConsumerTests {

    nonisolated static let fragment = "Q7z9"

    final class Transcript: @unchecked Sendable { var lines: [String] = [] }

    @Test("a click, a withheld text and a refused click through the tools: the rows, the task, no text of the person's anywhere")
    func theToolsRecordTheWebRung() async throws {
        let page = SyntheticPage(fields: TextTargetWebTests.fields)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "braus-web-rung-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let knowledge = root.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        let options = ChromeLaunchOptions(executableURL: root.appending(path: "no-chrome"),
                                          userDataDirectory: root.appending(path: "chrome-web"))
        let session = WebAutomationSession(knowledgeDirectory: knowledge, launchOptions: options,
                                           connectPersonalChrome: { try await WebBrowser.attached(over: page, readySeconds: 5) })
        session.usesPersonalChrome = true
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: .app, streamID: "web-rung-tools", traceID: "m1", messageRef: "m1")
        let transcript = Transcript()
        tools.record = { transcript.lines.append($0) }

        _ = try await tools.call("open_session", .object(["app": .string("web:fixture.test")]))
        let id = LocalMCP.JSONValue.string(try #require(session.id?.uuidString))
        _ = try await tools.call("memory_task", .object([
            "operation": .string("begin"), "goal": .string("Fill the form"), "remaining": .string("Fill the form"),
        ]))
        let clicked = try await tools.call("act", .object(["session": id, "target": .string("Nome")]))
        #expect(["found_acted", "acted_unverified"].contains(TypedSecretTests.status(of: clicked) ?? ""), "\(clicked)")
        #expect(page.pressCount == 1)
        let secret = "typed-\(Self.fragment)-web"
        let typedAnswer = try await tools.call("type_text", .object(["session": id, "target": .string("Accesso"), "text": .string(secret)]))
        #expect(page.textCount > 0, "the keys reached the page")
        _ = try await tools.call("memory_task", .object(["operation": .string("end"), "outcome": .string("completed")]))
        // The typed text clicked its field first, with the engine's own clicks: the presses so far are the click's
        // and those; the covered click adds no command and no press.
        page.change([.cover(CGRect(x: 100, y: 200, width: 300, height: 30), name: "Banner")])
        let mouseBefore = page.count(of: WebSend.Method.mouse.rawValue), pressesBefore = page.pressCount
        #expect(pressesBefore > 1, "the click and the typed text's clicks: \(pressesBefore)")
        let refused = try await tools.call("act", .object(["session": id, "target": .string("Nome")]))
        #expect(page.count(of: WebSend.Method.mouse.rawValue) == mouseBefore && page.pressCount == pressesBefore,
                "nothing sent: \(refused)")
        _ = try await tools.call("close_session", .object(["session": id]))

        // The archive: each call's row is its own.
        let memory = MemoryService.shared(for: knowledge)
        #expect(await memory.flush(within: .seconds(10)))
        let calls = try await memory.calls(inTrace: "m1").sorted { $0.localOrder < $1.localOrder }
        let acts = calls.filter { $0.request.tool == .act }
        let typed = calls.filter { $0.request.tool == .typeText }
        #expect(acts.count == 2 && typed.count == 1, "\(calls.map(\.request.tool))")
        let firstAct = try #require(acts.first).event.eventID
        let typedID  = try #require(typed.first).event.eventID
        let lastAct  = try #require(acts.last).event.eventID
        #expect(try await memory.perform { try await $0.facts.rung(of: firstAct) }
                == CallRung(rung: .webInputEvent, how: "Input.dispatchMouseEvent: 3 planned, 3 attempted, 3 acknowledged, completed"))
        #expect(try await memory.perform { try await $0.facts.attribution(of: firstAct) } != nil, "under the task")
        let typedRung = try await memory.perform { try await $0.facts.rung(of: typedID) }
        #expect(typedRung?.rung == .webInputEvent && typedRung?.how.hasPrefix("Input.dispatchKeyEvent: ") == true
                && typedRung?.how.hasSuffix(", completed") == true && typedRung?.how.contains(Self.fragment) == false,
                "\(String(describing: typedRung))")
        #expect(try await memory.perform { try await $0.facts.attribution(of: typedID) } != nil, "under the task")
        #expect(try await memory.perform { try await $0.facts.rung(of: lastAct) } == nil, "refused before any command: no rung")
        #expect(try await memory.perform { try await $0.facts.attribution(of: lastAct) } == nil, "after the task ended: no task")
        #expect(try await memory.perform { try await $0.facts.route(of: firstAct) }?.route == .web)
        // Nothing of the typed text anywhere, while the archive is open (its WAL live, after the flush) and once closed.
        #expect(try SecureFieldTests.files(in: knowledge, holding: Self.fragment).isEmpty, "the open archive holds the text")
        await memory.close()
        MemoryService.forget(knowledge)
        #expect(try SecureFieldTests.files(in: knowledge, holding: Self.fragment).isEmpty, "the closed archive holds the text")
        #expect(transcript.lines.filter { $0.contains(Self.fragment) }.isEmpty, "the transcript holds the text")
        #expect(!TypedSecretTests.strings(in: typedAnswer).contains { $0.contains(Self.fragment) }, "the answer holds the text")
        // The person's Chrome as the session found it: attached, one tab opened and closed, nothing launched.
        #expect(page.order(of: ["Browser.getVersion", "Target.createTarget", "Target.attachToTarget", "Target.closeTarget"])
                == ["Browser.getVersion", "Target.createTarget", "Target.attachToTarget", "Target.closeTarget"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "chrome-web").path), "no Chrome of Braus's launched")
    }

    @Test("a start the memory cannot confirm (its archive locked past a short budget) sends no command and records no rung; once the lock is gone the next call runs, nothing replayed")
    func anUnconfirmedStartSendsNothing() async throws {
        let page = SyntheticPage(fields: TextTargetWebTests.fields)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "braus-web-rung-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let knowledge = root.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        // The memory behind the session, with the short lock budget `FactWiringTests` uses, installed before the
        // session's runtime asks for the directory's shared service.
        let store = SQLiteMemoryStore.Configuration(lockBudget: .milliseconds(100), retryPause: .milliseconds(5),
                                                    maximumRetryPause: .milliseconds(10))
        let memory = MemoryService(directory: knowledge,
                                   configuration: MemoryService.Configuration(store: store, essentialAttempts: 1, essentialCycles: 1))
        MemoryService.install(memory)
        let options = ChromeLaunchOptions(executableURL: root.appending(path: "no-chrome"),
                                          userDataDirectory: root.appending(path: "chrome-web"))
        let session = WebAutomationSession(knowledgeDirectory: knowledge, launchOptions: options,
                                           connectPersonalChrome: { try await WebBrowser.attached(over: page, readySeconds: 5) })
        session.usesPersonalChrome = true
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: .app, streamID: "web-rung-lock", traceID: "m2", messageRef: "m2")
        _ = try await tools.call("open_session", .object(["app": .string("web:fixture.test")]))
        let id = LocalMCP.JSONValue.string(try #require(session.id?.uuidString))
        #expect(await memory.flush(within: .seconds(10)))

        // The archive is held by another writer: the call's start cannot be confirmed within the budget.
        let lock = try SQLiteConnection(path: memory.url.path)
        try lock.execute("BEGIN IMMEDIATE")
        let mouseBefore = page.count(of: WebSend.Method.mouse.rawValue)
        await #expect(throws: AutomationFailure.self) {
            _ = try await tools.call("act", .object(["session": id, "target": .string("Nome")]))
        }
        #expect(page.count(of: WebSend.Method.mouse.rawValue) == mouseBefore && page.pressCount == 0,
                "the memory refused the start: no command went out")
        try lock.execute("COMMIT")
        lock.close()

        // The lock gone, the next call runs and is recorded, once; the refused one left no row of any kind.
        let clicked = try await tools.call("act", .object(["session": id, "target": .string("Nome")]))
        #expect(["found_acted", "acted_unverified"].contains(TypedSecretTests.status(of: clicked) ?? ""), "\(clicked)")
        #expect(page.pressCount == 1)
        _ = try await tools.call("close_session", .object(["session": id]))
        #expect(await memory.flush(within: .seconds(10)))
        let calls = try await memory.calls(inTrace: "m2")
        let acts = calls.filter { $0.request.tool == .act }
        #expect(acts.count == 1, "the refused start is no call on the record, the next one is: \(calls.map(\.request.tool))")
        let act = try #require(acts.first).event.eventID
        #expect(try await memory.perform { try await $0.facts.rung(of: act) }
                == CallRung(rung: .webInputEvent, how: "Input.dispatchMouseEvent: 3 planned, 3 attempted, 3 acknowledged, completed"))
        await memory.close()
        MemoryService.forget(knowledge)
        let archive = try SQLiteConnection(path: memory.url.path, readOnly: true)
        defer { archive.close() }
        #expect(try archive.query("SELECT count(*) FROM memory_call_rungs") { try $0.integer(0) ?? 0 } == [1], "one rung in the archive")
    }
}
