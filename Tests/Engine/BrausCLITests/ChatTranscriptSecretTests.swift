import AutomationMCP
import AutomationRuntime
import ChatCore
import FileConversations
import Foundation
import LocalMCP
import Memory
import Testing
@testable import braus

/// D4a (M07 on the command line): once `memory_task` declares a secret, the chat never shows or saves it in a
/// provider's reply, its failure or a turn's error. The real `ChatSession`, on temporary folders and never started (no
/// provider, CLI, account or Seat), adopts the real `ChatTranscript`, which is where it gives the transcript its tools'
/// withholding; the test then passes the transcript the events `ChatSession.turn` passes, appends the error
/// `ChatCommand` appends when a turn throws, and records a script's evidence of the request. It reads the reply's
/// console lines, the saved conversation and the evidence folder. Without the wiring in `adopt`, the secret is there.
///
/// Exercised: `ChatSession.adopt`, `ChatTranscript.event`, `append` and `shown`, `ChatEvidence.record` (the
/// conversation copy, the summary's error and the provider's subtype), `ChatCommand.turnFailure` (what a `--once` or
/// non-interactive chat throws, which `main` prints). Source only: `ChatCommand`'s calls of `shown` and `turnFailure`
/// themselves, where a turn throws.
@MainActor
@Suite("D4a: the chat withholds a declared secret from replies, failures and errors")
struct ChatTranscriptSecretTests {

    static let secret = "Sentinel-Declared-D4a-Q7z9"

    /// A turn's error, as a provider failure would describe itself.
    struct TurnError: LocalizedError {
        let errorDescription: String?
    }

    /// The lines a transcript printed.
    final class Console { var lines: [String] = [] }

    static func files(under folder: URL) throws -> [URL] {
        try FileManager.default.subpathsOfDirectory(atPath: folder.path(percentEncoded: false))
            .map { folder.appending(path: $0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    @Test("adopted by the session: no secret in a reply's console line, a reply, failure, error, file or evidence")
    func adoptedTranscriptWithholds() async throws {
        let folder = URL.temporaryDirectory
            .appending(path: "braus-d4a-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let knowledge     = folder.appending(path: "Knowledge", directoryHint: .isDirectory)
        let history       = folder.appending(path: "History", directoryHint: .isDirectory)
        let conversations = folder.appending(path: "Conversations", directoryHint: .isDirectory)
        let evidence      = folder.appending(path: "Evidence", directoryHint: .isDirectory)
        for directory in [knowledge, history] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let options = try ChatOptions(arguments: ["--knowledge", knowledge.path(percentEncoded: false),
                                                  "--history-dir", history.path(percentEncoded: false)])
        let session = try ChatSession(options: options, history: history, executable: URL(filePath: "/usr/bin/false"))
        defer { session.stop() }

        let transcript = ChatTranscript(conversation: Conversation(provider: .claude, model: nil),
                                        store: try ConversationStore(directory: conversations))
        let console = Console()
        transcript.output = { console.lines.append($0) }
        try transcript.append(.assistant, "An earlier reply, saved before the conversation was adopted.")
        session.adopt(transcript)

        let begin: JSONValue = .object([
            "operation": .string("begin"), "goal": .string("Sign in to the fixture"),
            "remaining": .string("Sign in to the fixture"),
            "inputs": .array([.object(["name": .string("password"), "value": .string(Self.secret),
                                       "secret": .bool(true)])]),
        ])
        _ = try await session.tools.call("memory_task", begin)

        // What `ChatSession.turn` passes the transcript, then what `ChatCommand` appends when the turn throws.
        try transcript.event(.assistant("Signed in with \(Self.secret)."))
        try transcript.event(.assistant("The page is open."))
        try transcript.event(.failure("Could not use \(Self.secret)."))
        try transcript.append(.error, "The provider stopped: \(Self.secret) was refused.")
        let turnError = TurnError(errorDescription: "The provider stopped: \(Self.secret) was refused.")
        let providerError = ProviderFailure(kind: .apiError, message: "Refused: \(Self.secret).",
                                            subtype: "denied_\(Self.secret)")
        let records = try ChatEvidence(directory: evidence)
        try records.record(
            number: 1, request: "Sign in to the fixture", continues: false, transcript: transcript, started: Date(),
            ended: Date(), failure: turnError, abandonment: nil, toolCalls: 1, memoryFlushed: true, archive: knowledge)
        try records.record(
            number: 2, request: "Sign in again", continues: true, transcript: transcript, started: Date(),
            ended: Date(), failure: providerError, abandonment: nil, toolCalls: 1, memoryFlushed: true,
            archive: knowledge)

        // What a `--once` chat throws, and `main` prints, keeps the provider's kind and not the secret.
        let thrown = ChatCommand.turnFailure(providerError, shownBy: transcript)
        #expect(thrown.description.contains("api_error"), "\(thrown)")
        #expect(!"\(thrown)".contains("Q7z9") && !thrown.localizedDescription.contains("Q7z9"))
        #expect(!"\(ChatCommand.turnFailure(turnError, shownBy: transcript))".contains("Q7z9"))

        let entries = transcript.conversation.entries
        #expect(entries.filter { $0.kind == .assistant || $0.kind == .error }.count == 5)
        #expect(entries.first?.text == "An earlier reply, saved before the conversation was adopted.", "kept as saved")
        #expect(entries.contains { $0.kind == .assistant && $0.text == "The page is open." },
                "an innocuous reply is kept")
        for entry in entries.dropFirst() {
            #expect(!entry.text.contains(Self.secret) && !entry.text.contains("Q7z9"), "\(entry.kind): \(entry.text)")
        }
        #expect(console.lines.count == 2)
        #expect(console.lines.contains { $0.contains("The page is open.") })
        #expect(!console.lines.contains { $0.contains(Self.secret) || $0.contains("Q7z9") }, "\(console.lines)")
        #expect(!transcript.shown("Chat error: \(Self.secret)").contains("Q7z9"), "the console line of a turn's error")

        let written = try Self.files(under: conversations) + Self.files(under: evidence)
        #expect(written.contains { $0.lastPathComponent == "conversation.json" }, "the evidence copy was written")
        #expect(written.contains { $0.lastPathComponent == "summary.json" })
        for file in written {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(Self.secret) && !text.contains("Q7z9"), "\(file.lastPathComponent) holds the secret")
        }

        // The person's own message stays as they wrote it.
        try transcript.append(.user, "My password is \(Self.secret)")
        #expect(transcript.conversation.entries.last?.text == "My password is \(Self.secret)")
        await MemoryService.closeAll()
    }
}
