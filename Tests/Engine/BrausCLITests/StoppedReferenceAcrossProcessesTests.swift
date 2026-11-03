import AutomationRuntime
import AutomationMCP
import TestScratch
import ChatCore
import FileConversations
import Foundation
import LocalMCP
import Memory
import Switches
import Testing
@testable import SQLiteMemory
@testable import braus

/// Two real chat sessions share only the archive and saved conversation, with a fake provider and Seat.
@MainActor
@Suite(.serialized, .enabled(if: SQLiteMemorySchema.version >= 22, "Requires DB2 to activate schema 22"))
struct StoppedReferenceAcrossProcessesTests {
    @Test(arguments: [true, false])
    func resumedOnceRestoresOnlyAnExplicitStop(_ stopped: Bool) async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["task_cycle": "v2", "tool_surface": "v2"])) {
            let root = URL.temporaryDirectory.appending(path: "tu6-chat-\(UUID().uuidString)")
            let knowledge = root.appending(path: "Knowledge")
            try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
            let store = try ConversationStore(directory: root.appending(path: "Conversations"))
            let output = root.appending(path: "output.txt")
            var saved: Conversation?
            var stoppedID: String?
            let first = try ChatTurnAuthorityTests.Chat()
            first.counting.memoryDirectory = knowledge
            try await first.running {
                try first.adoptNew()
                let turn = first.turn("Prepare and inspect the result")
                let connection = try await first.connection(of: 0)
                let client = try first.client(connection)
                let plan = try await client.ask("tools/call", .object(["name": .string("plan"), "arguments": .object([
                    "request": .string("Prepare and inspect the result"),
                    "inputs": .array([.object(["name": .string("output"), "kind": .string("file"), "value": .string(output.path)])]),
                    "rows": .array([
                        .object(["title": .string("Prepare the result"), "expect": .object(["file_written": .string(output.path)])]),
                        .object(["title": .string("Inspect the result")])])])]))
                let begun = ChatScript.payload(of: plan["result"])
                stoppedID = try #require(begun["task"].string)
                _ = try await client.ask("tools/call", .object(["name": .string("open_session"),
                    "arguments": .object(["app": .string("Notes")])]))
                _ = try await client.ask("tools/call", .object(["name": .string("act"), "arguments": .object([
                    "target": .string("Prepare"), "step": .string("r1")])]))
                try Data("synthetic result".utf8).write(to: output)
                _ = try await client.ask("tools/call", .object(["name": .string("act"), "arguments": .object([
                    "target": .string("Inspect"), "step": .string("r2")])]))
                try first.go(0)
                try await turn.value
                if stopped {
                    _ = try await first.session.tools.closeStoppedTask(.signal(15))
                    let notice = try #require(first.session.tools.takeStoppedTaskNotice())
                    let taskID = try #require(stoppedID)
                    #expect(!notice.contains(taskID))
                } else {
                    _ = try await first.session.tools.call("end", .object(["outcome": .string("abandoned")]))
                }
                saved = try #require(first.session.current).conversation
                let transcript = ChatTranscript(conversation: try #require(saved), store: store)
                try transcript.save()
            }
            // The first process closed its services; the simulated second process must create its own.
            RecallService.forget(MemoryService.shared(for: knowledge))
            MemoryService.forget(knowledge)
            let conversation = try #require(saved)
            let second = try ChatTurnAuthorityTests.Chat(resuming: conversation.id, once: "Continue the work")
            second.counting.memoryDirectory = knowledge
            try await second.running {
                second.session.adopt(ChatTranscript(conversation: conversation, store: store))
                let turn = second.turn("Continue the work")
                let connection = try await second.connection(of: 0)
                let client = try second.client(connection)
                let result = try await client.ask("tools/call", .object(["name": .string("plan"), "arguments": .object([
                    "request": .string("Continue the work"), "rows": .array([.object(["title": .string("Continue")])])])]))
                let answer = ChatScript.payload(of: result["result"])
                if stopped {
                    #expect(answer["continues"]["task"].string == stoppedID)
                    #expect(answer["continues"]["verified_rows"].array?.map { $0["title"].string } == ["Prepare the result"])
                    #expect(answer["continues"]["uncertain_gesture"].string == "not_known")
                } else { #expect(answer["continues"] == .null) }
                try second.go(0)
                try await turn.value
            }
            try FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
struct StopUnifiedTests {
    @Test func cliUsesTheSameIdentityFreeNoticeInV2() {
        SwitchBoard.$testing.withValue(SwitchBoard(values: ["task_cycle": "v2"])) {
            let line = ChatSession.line(for: .init(task: "private-task-id", closed: true, problem: nil))
            #expect(line == "Braus stopped the previous task and closed it as abandoned, not completed. "
                + "Plan the current request as a new task; plan's answer lists the rows of the stopped task "
                + "that were done and verified. Observe current effects first; never repeat an uncertain action.")
            #expect(!line.contains("private-task-id"))
        }
    }
}
