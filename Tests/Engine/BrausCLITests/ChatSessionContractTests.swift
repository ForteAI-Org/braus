import AutomationRuntime
import ChatCore
import Capabilities
import FileConversations
import Foundation
import LocalMCP
import Memory
import Testing
import Turn
@testable import braus

@MainActor
@Suite("Chat session turn contract")
struct ChatSessionContractTests {
    @Test func commandLineMatchesTheSharedFixture() async throws {
        var source = URL(filePath: #filePath)
        for _ in 0..<4 { source.deleteLastPathComponent() }
        let fixtures = source.appending(path: "Tests/Turn/Fixtures")
        let root = URL.temporaryDirectory.appending(path: "braus-chat-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let script = root.appending(path: "provider.py")
        try FileManager.default.copyItem(at: fixtures.appending(path: "provider.py"), to: script)
        try FileManager.default.copyItem(at: source.appending(path: "Tests/Chat/Fixtures/claude-turn1.jsonl"),
                                        to: root.appending(path: "reply.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let options = try ChatOptions(arguments: ["--knowledge", root.appending(path: "knowledge").path])
        let session = try ChatSession(options: options, history: root.appending(path: "history"), executable: script,
                                      session: { _ in ChatTurnAuthorityTests.CountingSession() })
        let store = try ConversationStore(directory: root.appending(path: "conversations"))
        let transcript = ChatTranscript(conversation: Conversation(provider: .claude, model: nil), store: store)
        session.adopt(transcript)
        do {
            try await session.turn("Hello")
            let outcome = try #require(transcript.lastOutcome)
            let received = try JSONDecoder().decode(LocalMCP.JSONValue.self, from: Data(contentsOf: root.appending(path: "received.json")))
            let values = try #require(received["arguments"].array)
        let arguments = values.compactMap { $0.string }
            let index = try #require(arguments.firstIndex(of: "--append-system-prompt"))
            let snapshot: LocalMCP.JSONValue = .object([
                "appText": .bool(arguments[index + 1] == TurnRunner.systemPrompt(role: nil,
                    toolNames: ToolList.names(attendance: session.tools.toolList.attendance, level: session.tools.toolList.level).map(\.rawValue),
                    groupIndex: session.tools.groupIndex, guidesEnabled: session.tools.guidesEnabled)),
                "ending": .string("completed"), "prompt": received["standardInput"], "reply": .string(transcript.conversation.entries.filter { $0.kind == .assistant }.map(\.text).joined()),
                "toolCalls": .number(Double(outcome.toolCalls)),
                "usage": try JSONDecoder().decode(LocalMCP.JSONValue.self, from: JSONEncoder().encode(outcome.usage))
            ])
            let expected = try JSONDecoder().decode(LocalMCP.JSONValue.self,
                from: Data(contentsOf: fixtures.appending(path: "contract-command-line.json")))
            #expect(snapshot == expected)
            #expect(transcript.requestTokens == outcome.usage?.tokens)
        } catch {
            await session.finish()
            session.stop()
            await MemoryService.closeAll()
            throw error
        }
        await session.finish()
        session.stop()
        await MemoryService.closeAll()
    }
}
