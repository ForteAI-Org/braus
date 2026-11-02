//
//  ScriptedWorkerTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AutomationRuntime
import ChatCore
import Foundation
import LocalMCP
import ModelTransports
import Testing
@testable import Braus

@Suite
@MainActor
struct ScriptedWorkerTests {

    @Test
    func resolvesSessionForTheNextRoundAndSavesReturnedPNGs() async throws {
        let root = URL.temporaryDirectory.appending(path: "scripted-canvas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString
        let script = try ScriptedWorkerScript(data: Data("""
            [
              {"calls":[{"tool":"open_session","arguments":{"app":"CanvasFixture"}}]},
              {"calls":[{"tool":"observe","arguments":{"session":"$session"}}]},
              {"calls":[{"tool":"canvas","arguments":{"id":"canvas 1"}}]},
              {"answer":"Finished."}
            ]
            """.utf8))
        let run = try ScriptedWorkerRun(
            script : script,
            support: root
        )
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=="
        let loop = ModelToolLoop(
            call: { name, arguments in
                if name == "observe" { #expect(arguments["session"] == .string(session)) }
                if name != "canvas" {
                    return .object(["content": .array([
                        .object(["type": .string("text"), "text": .string("A readable scene.")])
                    ]), "structuredContent": .object(["session": .string(session)])])
                }
                let image: JSONValue = .object([
                    "type": .string("image"), "mimeType": .string("image/png"), "data": .string(png)
                ])
                return .object(["content": .array([
                    .object(["type": .string("text"), "text": .string("before, after")]), image, image
                ])])
            },
            recordResult: { call, result, startedAt in
                try run.record(
                    call     : call,
                    result   : result,
                    startedAt: startedAt
                )
            }
        )
        try await loop.run(
            transport: run.transport,
            role     : nil,
            history  : [],
            prompt   : "Start."
        ) { _ in }
        let log = try String(
            contentsOf: root.appending(path: "scripted-tools.jsonl"),
            encoding  : .utf8
        )
        let last = try #require(log.split(separator: "\n").last)
        let entry = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(last.utf8)
        )
        let images = try #require(entry["images"].array)
        #expect(images.count == 2)
        for image in images {
            #expect(image["width"] == .number(1))
            #expect(image["height"] == .number(1))
            let file = try #require(image["file"].string)
            #expect(try Data(contentsOf: root.appending(path: file)) == Data(base64Encoded: png))
        }
    }

    @Test
    func refusesSessionPlaceholderBeforeAnySession() throws {
        let script = try ScriptedWorkerScript(data: Data("""
            [{"calls":[{"tool":"observe","arguments":{"session":"$session"}}]},{"answer":"Done"}]
            """.utf8))
        let transport = ScriptedWorkerTransport(script: script)
        #expect(throws: AutomationFailure.self) {
            try transport.converse(
                [],
                tools  : [],
                timeout: 1
            )
        }
    }

    @Test
    func parsesOrderedCallsAndAFinalAnswer() throws {
        let script = try ScriptedWorkerScript(data: Data("""
            [
              {"calls":[
                {"tool":"status","arguments":{}},
                {"tool":"windows","arguments":{"app":"TextEdit"}}
              ]},
              {"answer":"Finished."}
            ]
            """.utf8))
        #expect(script.rounds.count == 2)
        #expect(script.rounds[0].count == 3)
        guard case .toolCall(let call) = script.rounds[0][1] else {
            Issue.record("The second call was lost.")
            return
        }
        #expect(call.name == "windows")
        let arguments = try JSONDecoder().decode(
            JSONValue.self,
            from: call.arguments
        )
        #expect(arguments == .object(["app": .string("TextEdit")]))
        #expect(script.rounds[1].first == .delta("Finished."))
    }

    @Test(arguments: [
        "[]", "{}", "[{}]", #"[{"answer":""}]"#,
        #"[{"calls":[]},{"answer":"Done"}]"#,
        #"[{"answer":"Early"},{"answer":"Done"}]"#,
        #"[{"calls":[{"tool":"status","arguments":[]}]}]"#,
        #"[{"calls":[{"tool":"","arguments":{}}]},{"answer":"Done"}]"#,
        #"[{"calls":[{"tool":"status","arguments":{}}]}]"#,
        #"[{"calls":[],"answer":"Done"}]"#,
    ])
    func rejectsInvalidScripts(_ json: String) {
        #expect(throws: (any Error).self) { try ScriptedWorkerScript(data: Data(json.utf8)) }
    }

    @Test(arguments: [LaunchIsolation.off, .invalid(reason: "Invalid")])
    func ignoresTheOverrideOutsideValidIsolation(_ isolation: LaunchIsolation) throws {
        let path = try ScriptedWorkerRun.scriptURL(
            isolation  : isolation,
            environment: ["BRAUS_SCRIPTED_WORKER": "relative-and-missing.json"]
        )
        #expect(path == nil)
    }

    @Test
    func requiresAnAbsolutePathOnlyWhenIsolated() throws {
        let isolation = LaunchIsolation.isolated(support: URL(fileURLWithPath: "/scratch"))
        #expect(throws: (any Error).self) {
            try ScriptedWorkerRun.scriptURL(
                isolation  : isolation,
                environment: ["BRAUS_SCRIPTED_WORKER": "relative"]
            )
        }
        let absent = try ScriptedWorkerRun.scriptURL(
            isolation  : isolation,
            environment: [:]
        )
        #expect(absent == nil)
        let path = try ScriptedWorkerRun.scriptURL(
            isolation  : isolation,
            environment: ["BRAUS_SCRIPTED_WORKER": "/script.json"]
        )
        #expect(path?.path == "/script.json")
    }

    @Test
    func theRealLoopAuditsResultsErrorsAndPictures() async throws {
        let root = URL.temporaryDirectory.appending(path: "scripted-worker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try ScriptedWorkerScript(data: Data("""
            [
              {"calls":[{"tool":"status","arguments":{}},{"tool":"windows","arguments":{}}]},
              {"answer":"Finished."}
            ]
            """.utf8))
        let run = try ScriptedWorkerRun(
            script : script,
            support: root
        )
        let loop = ModelToolLoop(
            call: { name, _ in
                if name == "windows" { throw AutomationFailure("A recorded refusal.") }
                return .object(["content": .array([
                    .object(["type": .string("text"), "text": .string("Read-only result")]),
                    .object(["type": .string("image"), "data": .string("fixture")]),
                ])])
            },
            recordResult: { call, result, startedAt in
                try run.record(
                    call     : call,
                    result   : result,
                    startedAt: startedAt
                )
            }
        )
        try await loop.run(
            transport: run.transport,
            role     : nil,
            history  : [],
            prompt   : "Start."
        ) { _ in }
        run.finish()
        let lines = try String(
            contentsOf: root.appending(path: "scripted-tools.jsonl"),
            encoding  : .utf8
        )
        .split(separator: "\n")
        .map {
            try JSONDecoder().decode(
                JSONValue.self,
                from: Data($0.utf8)
            )
        }
        #expect(lines.count == 2)
        #expect(lines[0]["tool"] == .string("status"))
        #expect(lines[0]["round"] == .number(1))
        #expect(lines[0]["hasImage"] == .bool(true))
        #expect(lines[1]["error"].string?.contains("A recorded refusal.") == true)
        #expect(lines[1]["hasImage"] == .bool(false))
        #expect(run.report.roundsPlayed == 2)
        #expect(run.report.completed)
        #expect(run.report.errors.count == 1)
        #expect(run.report.launchToFirstToolMs != nil)
        #expect(throws: ModelTransportError.self) {
            try run.transport.converse(
                [],
                tools  : [],
                timeout: 1
            )
        }
    }

    @Test(arguments: ModelProvider.allCases)
    func everyProviderUsesTheScriptWithoutConstructingAProvider(_ provider: ModelProvider) async throws {
        let root = URL.temporaryDirectory.appending(path: "scripted-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try ScriptedWorkerRun(
            script : ScriptedWorkerScript(data: Data(#"[{"answer":"Scripted answer."}]"#.utf8)),
            support: root
        )
        var askedProvider = false
        let host = WorkerAgentHost(
            workingDirectory: root,
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { DesktopUnavailableSession() },
            agents          : { _ in
                askedProvider = true
                throw AutomationFailure("No CLI may start.")
            },
            transports      : { _ in
                askedProvider = true
                return run.transport
            },
            scriptedWorker  : { run }
        )
        var answered = false
        try await host.run(
            prompt   : "Start.",
            selection: ModelSelection(
                provider: provider,
                model   : "unused",
                effort  : .low
            ),
            sessionID: nil,
            role     : nil
        ) { event in
            if case .provider(.assistant("Scripted answer.")) = event { answered = true }
        }
        #expect(answered)
        #expect(!askedProvider)
        #expect(host.scriptedReport?.completed == true)
        try await host.close()
    }

    @Test
    func aMalformedScriptFailsBeforeConstructingAProvider() async throws {
        var askedProvider = false
        let host = WorkerAgentHost(
            workingDirectory: URL.temporaryDirectory,
            bridgeExecutable: URL(fileURLWithPath: "/nonexistent"),
            session         : { DesktopUnavailableSession() },
            agents          : { _ in
                askedProvider = true
                throw AutomationFailure("No CLI may start.")
            },
            scriptedWorker  : {
                _ = try ScriptedWorkerScript(data: Data("[]".utf8))
                return nil
            }
        )
        await #expect(throws: AutomationFailure.self) {
            try await host.run(
                prompt   : "Start.",
                selection: ModelSelection(
                    provider: .codex,
                    model   : "unused",
                    effort  : .low
                ),
                sessionID: nil,
                role     : nil
            ) { _ in }
        }
        #expect(!askedProvider)
        #expect(host.scriptedReport?.roundsPlayed == 0)
        #expect(host.scriptedReport?.errors.count == 1)
        try await host.close()
    }

    @Test
    func anUnwritableResultAuditFailsTheLoop() async throws {
        let root = URL.temporaryDirectory.appending(path: "scripted-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try ScriptedWorkerRun(
            script : ScriptedWorkerScript(data: Data("""
                [{"calls":[{"tool":"status","arguments":{}}]},{"answer":"Done."}]
                """.utf8)),
            support: root
        )
        let log = root.appending(path: "scripted-tools.jsonl")
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(
            at                         : log,
            withIntermediateDirectories: false
        )
        let loop = ModelToolLoop(
            call        : { _, _ in .object([:]) },
            recordResult: { call, result, startedAt in
                try run.record(
                    call     : call,
                    result   : result,
                    startedAt: startedAt
                )
            }
        )
        await #expect(throws: (any Error).self) {
            try await loop.run(
                transport: run.transport,
                role     : nil,
                history  : [],
                prompt   : "Start."
            ) { _ in }
        }
        #expect(run.transport.roundsPlayed == 1)
        #expect(!run.report.completed)
    }


    @Test
    func isolatedPreferencesPersistOnlyAtTheirAbsoluteSupportPath() throws {
        let root = URL.temporaryDirectory.appending(path: "scripted-preferences-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at                         : root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppDefaults.isolatedStore(in: root)
        store.set(true, forKey: "isolated.preference.probe")
        #expect(store.synchronize())
        let bytes = try Data(contentsOf: root.appending(path: "preferences.plist"))
        let plist = try PropertyListSerialization.propertyList(
            from   : bytes,
            options: [],
            format : nil
        ) as? [String: Any]
        #expect(plist?["isolated.preference.probe"] as? Bool == true)
    }

}
