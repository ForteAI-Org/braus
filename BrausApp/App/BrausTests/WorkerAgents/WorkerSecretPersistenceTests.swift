//
//  WorkerSecretPersistenceTests.swift
//  Braus
//

import ChatCore
import Foundation
import ModelTransports
import Synchronization
import Testing
@testable import Braus

/// M07 through the worker's own path, to the workspace's files: a secret a task declares in a loop turn's
/// `memory_task` is in no file of the workspace afterwards, whatever the turns carry once it is known: the worker's
/// reply, a command line's own web search and page read, the note before them, its failure's reason. The provider is
/// a stand-in, the desktop unavailable, the store temporary and reopened as a relaunch would open it.
///
/// What is proved is the tools' classification of the secret, which `memory_task` makes before anything else, and the
/// workspace writer withholding it: the task itself may be refused (the unavailable desktop has no memory), and
/// nothing here claims the living memory kept anything.
@MainActor
struct WorkerSecretPersistenceTests {

    /// The synthetic secret, and a fragment of it no piece may leave in a file.
    static let secret   = "Sentinel-Declared-M07-Q7z9"
    static let fragment = "Q7z9"

    static let usage = ModelUsage(inputTokens: nil, outputTokens: nil, duration: .zero)

    @Test("M07: a declared secret is in no file of the workspace after a loop turn and a command line turn that carry it, the store reopened")
    func declaredSecretIsInNoWorkspaceFile() async throws {
        let root = URL.temporaryDirectory.appending(path: "braus-m07-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "store", directoryHint: .isDirectory)
        let work      = root.appending(path: "work", directoryHint: .isDirectory)

        // Turn 1, Braus's own loop: the model declares the secret in memory_task, then names it in its reply.
        let begin = ToolCall(id: "call_0", name: "memory_task", arguments: Data(#"""
            {"operation":"begin","goal":"Sign in to the fixture","remaining":"Sign in to the fixture",
             "inputs":[{"name":"password","value":"\#(Self.secret)","secret":true}]}
            """#.utf8))
        let transport = Script(rounds: [
            [.toolCall(begin), .completed(Self.usage)],
            [.delta("I will use \(Self.secret) to sign in."), .completed(Self.usage)],
        ])
        // Turn 2, a command line: a note naming the secret, its own web search and page read carrying it, and a
        // failure naming it. Turn 3, the same command line again: an answer naming it, a turn that completes, so the
        // host also writes its record of the instructions in its working folder.
        let standIn = root.appending(path: "claude")
        let note    = #"{"type":"text","text":"Searching for \#(Self.secret)."}"#
        let search  = #"{"type":"tool_use","id":"t1","name":"WebSearch","input":{"query":"reset \#(Self.secret)"}}"#
        let fetch   = #"{"type":"tool_use","id":"t2","name":"WebFetch","input":"#
            + #"{"url":"https://fixture.invalid/?q=\#(Self.secret)"}}"#
        let results = #"{"type":"tool_result","tool_use_id":"t1","content":"ok"},"#
            + #"{"type":"tool_result","tool_use_id":"t2","content":"ok"}"#
        let failure = #"{"type":"result","subtype":"error_during_execution","is_error":true,"#
            + #""result":"Could not use \#(Self.secret).","session_id":"s1"}"#
        let signedIn = #"{"type":"assistant","session_id":"s1","message":{"content":"#
            + #"[{"type":"text","text":"Signed in with \#(Self.secret)."}]}}"#
        let success = #"{"type":"result","subtype":"success","is_error":false,"#
            + #""result":"Signed in with \#(Self.secret).","session_id":"s1"}"#
        let once = root.appending(path: "failed-once").path
        try Data("""
        #!/bin/sh
        cat >/dev/null
        echo '{"type":"system","subtype":"init","session_id":"s1","model":"m"}'
        if [ -e '\(once)' ]; then
            echo '\(signedIn)'
            echo '\(success)'
            exit 0
        fi
        touch '\(once)'
        echo '{"type":"assistant","session_id":"s1","message":{"content":[\(note),\(search),\(fetch)]}}'
        echo '{"type":"user","session_id":"s1","message":{"content":[\(results)]}}'
        echo '\(failure)'

        """.utf8).write(to: standIn)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standIn.path)

        let host = WorkerAgentHost(workingDirectory: work, bridgeExecutable: standIn,
                                   session: { DesktopUnavailableSession() },
                                   agents: { _ in (.claude, standIn) }, transports: { _ in transport })
        let worker      : UUID
        let conversation: UUID
        var endings     : [WorkerTurnRecorder.Ending] = []
        do {
            let store = try WorkspaceStore.opening(in: directory)
            worker = try await store.createWorker(name: "Secret", appearance: TemporaryStore.appearance()).id
            conversation = try await store.createConversation(participants: [worker]).id
            let commandLine = ModelSelection(provider: .claudeCode, model: "claude-sonnet-5", effort: .low)
            for selection in [ModelSelection(provider: .ollama, model: "qwen3:8b", effort: .high), commandLine,
                              commandLine] {
                try await store.configure(worker: worker, selection: selection)
                let message  = try await store.appendMessage(to: conversation, text: "Sign in to the fixture.")
                let recorder = WorkerTurnRecorder(store: store, workspaceID: UUID(), workerID: worker,
                                                  conversationID: conversation, messageID: message.id,
                                                  withholding: host.withheld) {}
                endings.append(try await recorder.run { frozen, session, emit in
                    try await host.run(prompt: "Sign in to the fixture.", selection: frozen, sessionID: session,
                                       role: nil, allowsWebSearch: true, onEvent: emit)
                })
            }
            try await host.close()
        }
        // What memory_task answered the model: accepted or refused, it holds no piece of the secret.
        let answer = try #require(transport.sent.flatMap { $0 }.first { $0.role == .tool && $0.call?.id == "call_0" })
        print("memory_task answered:", answer.isError ? "error" : "result", answer.text.prefix(300))
        #expect(!answer.text.contains(Self.fragment), "\(answer.text)")
        #expect(endings.count == 3 && endings.first == .completed && endings.last == .completed, "\(endings)")
        guard endings.count == 3, case .failed = endings[1] else {
            Issue.record("the command line's first turn did not fail as scripted: \(endings)")
            return
        }

        // A relaunch: the store reopened reads the turns back, each with the secret withheld.
        let reopened = try WorkspaceStore.opening(in: directory)
        let replies  = try await reopened.messages(in: conversation).filter { $0.authorWorkerID == worker }.map(\.text)
        let records  = try await reopened.events(matching: EventQuery(scope: .conversation(conversation)))
            .compactMap(WorkerTurnRecorder.text(of:))
        // The secret was classified: each text that carried it is there, with the secret withheld in its place.
        #expect(replies.contains("I will use [withheld] to sign in."), "\(replies)")
        #expect(replies.contains("Signed in with [withheld]."), "\(replies)")
        #expect(records.contains(ToolStep.noteRecord("Searching for [withheld].")), "\(records)")
        #expect(records.contains(#"→ web_search {"query":"reset [withheld]"}"#), "\(records)")
        #expect(records.contains(#"→ web_fetch {"url":"https://fixture.invalid/?q=[withheld]"}"#), "\(records)")
        #expect(records.contains("Could not use [withheld]."), "\(records)")
        for text in replies + records {
            #expect(!text.contains(Self.fragment), "\(text)")
        }

        // No piece of the secret in any file the workspace or the host's working folder holds.
        let forms = [Self.secret, Self.fragment]
        for folder in [directory, work] {
            var read = 0
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            while let file = files?.nextObject() as? URL {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let data = try Data(contentsOf: file)
                read += 1
                for form in forms {
                    #expect(data.range(of: Data(form.utf8)) == nil, "\(file.lastPathComponent) holds \(form)")
                }
            }
            print("files read in \(folder.lastPathComponent):", read)
            #expect(read > 0, "no file was read in \(folder.lastPathComponent)")
        }
    }
}

/// A transport that answers each round from its script and keeps what it was sent.
private final class Script: ModelTransport {

    private let rounds: Mutex<[[TurnEvent]]>
    private let kept  = Mutex<[[TurnMessage]]>([])

    init(rounds: [[TurnEvent]]) { self.rounds = Mutex(rounds) }

    /// The messages of each round, in order.
    var sent: [[TurnMessage]] { kept.withLock { $0 } }

    var streaming: StreamingSupport { .incremental }

    func complete(prompt: String, schema: Data,
                  timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
        throw ModelTransportError.streamingUnsupported("a scripted transport has no structured request")
    }

    func capabilities() async throws -> ModelCapabilities { ModelCapabilities(supportsTools: true) }

    func converse(
        _ messages: [TurnMessage],
        tools     : [ToolDefinition],
        timeout   : TimeInterval
    ) throws -> AsyncThrowingStream<TurnEvent, any Error> {
        kept.withLock { $0.append(messages) }
        let events = rounds.withLock { $0.isEmpty ? [] : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
