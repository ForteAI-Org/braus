import AutomationRuntime
import ChatCore
import CLIProviders
import FileConversations
import Foundation
import LocalMCP
import Memory
import ModelTransports
import Synchronization
import Testing
@testable import braus

@MainActor
@Suite(.serialized) struct ChatLoopTests {
    @Test func effortReachesTheLoopAndKeychainFeedsOnlyTheTransport() async throws {
        let root = URL.temporaryDirectory.appending(path: "braus-chat-loop-\(UUID().uuidString)")
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let options = try ChatOptions(arguments: ["--model-provider", "anthropic", "--model", "claude-opus-5-5", "--effort", "high",
            "--provider-key-service", "test.service", "--knowledge", root.appending(path: "knowledge").path])
        let transport = ChatTransport()
        var settings: ProviderSettings?
        let session = try ChatSession(options: options, history: root.appending(path: "history"),
            executable: URL(filePath: "/unused"), session: { _ in ChatTurnAuthorityTests.CountingSession() },
            keychain: FakeKeychain(), makeTransport: { selection, received in
                #expect(selection.provider == .anthropic)
                #expect(selection.effort == .high)
                settings = received
                return transport
            })
        let store = try ConversationStore(directory: root.appending(path: "conversations"))
        let transcript = ChatTranscript(conversation: Conversation(provider: .claude, model: "claude-opus-5-5", modelProvider: "anthropic"), store: store)
        session.adopt(transcript)
        do {
            try transcript.append(.user, "Hello")
            try await session.turn("Hello")
            try transcript.append(.user, "Again")
            try await session.turn("Again")
            try transcript.save()
            let saved = try store.load(transcript.conversation.id)
            #expect(saved.modelProvider == "anthropic")
            #expect(saved.entries.contains { $0.kind == .assistant && $0.text == "Done." })
            #expect(settings?.anthropicAPIKey == "fake-secret")
            let keyInEnvironment = ProcessInfo.processInfo.environment.values.contains("fake-secret")
            #expect(!keyInEnvironment)
            #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("fake-secret"))
            #expect(transport.sent.count == 3)
            #expect(transport.sent.last?.contains { $0.role == .user && $0.text == "Hello" } == true)
            #expect(transport.sent.last?.contains { $0.role == .assistant && $0.text == "Done." } == true)
        } catch {
            await session.finish()
            session.stop()
            await MemoryService.shared(for: session.knowledge).close()
            throw error
        }
        await session.finish()
        session.stop()
        await MemoryService.shared(for: session.knowledge).close()
    }

    @Test func pauseWaitsForALineAndOffNeverReads() async throws {
        var printed: [String] = []
        var release: CheckedContinuation<String?, Never>?
        let wait = Task {
            try await ChatCommand.continueScript(hasNext: true, pause: true, output: { printed.append($0) }, input: {
                await withCheckedContinuation { release = $0 }
            })
        }
        while release == nil { await Task.yield() }
        #expect(printed == ["ready for next request"])
        release?.resume(returning: "")
        #expect(try await wait.value)
        #expect(try await ChatCommand.continueScript(hasNext: true, pause: false, output: { _ in Issue.record("Unexpected output") },
            input: { Issue.record("Unexpected input"); return nil }))
        #expect(try await ChatCommand.continueScript(hasNext: true, pause: true, output: { _ in }, input: { nil }) == false)
        #expect(try await ChatCommand.continueScript(hasNext: false, pause: true, output: { _ in Issue.record("No next request") },
            input: { Issue.record("No next request"); return nil }))
    }

    @Test func eofRunsCleanupOnceAndOtherBoundariesDoNot() async throws {
        var cleanups = 0
        let onEOF = { @MainActor in cleanups += 1 }
        #expect(await ChatCommand.continueScript(hasNext: true, pause: true,
            output: { _ in }, input: { nil }, onEOF: onEOF) == false)
        #expect(cleanups == 1)
        #expect(await ChatCommand.continueScript(hasNext: true, pause: true,
            output: { _ in }, input: { "" }, onEOF: onEOF))
        #expect(await ChatCommand.continueScript(hasNext: true, pause: false,
            output: { _ in }, input: { nil }, onEOF: onEOF))
        #expect(await ChatCommand.continueScript(hasNext: false, pause: true,
            output: { _ in }, input: { nil }, onEOF: onEOF))
        #expect(cleanups == 1)
    }

    private struct FakeKeychain: KeychainReading {
        func password(service: String) throws(ProviderKeychainKey.Failure) -> String {
            #expect(service == "test.service")
            return "fake-secret"
        }
    }
}

private final class ChatTransport: ModelTransport {
    private let messages = Mutex<[[TurnMessage]]>([])
    var sent: [[TurnMessage]] { messages.withLock { $0 } }
    var streaming: StreamingSupport { .incremental }
    func capabilities() async throws -> ModelCapabilities { ModelCapabilities(supportsTools: true) }
    func complete(prompt: String, schema: Data, timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
        throw ProviderError.badResponse("unused")
    }
    func converse(_ history: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let index = messages.withLock { messages in messages.append(history); return messages.count }
        return AsyncThrowingStream { continuation in
            if index == 1 {
                continuation.yield(.toolCall(ToolCall(id: "read", name: "status", arguments: Data("{}".utf8))))
            } else { continuation.yield(.delta(index == 3 ? "Done. fake-secret" : "Done.")) }
            continuation.yield(.completed(ModelUsage(inputTokens: 100, outputTokens: 2, duration: .zero)))
            continuation.finish()
        }
    }
}
