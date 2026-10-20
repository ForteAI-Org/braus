import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Darwin
import FileConversations
import Foundation
import LocalMCP
import Memory
import PrivateSymbols

/// ChatCommand composes the terminal, provider adapter, transcript store and one ephemeral MCP host (`ChatSession`).
/// Provider processes may exit between turns; the Seat belongs to this process until release or shutdown. With
/// `--script` it runs the file's requests one chat each on one archive, leaving evidence per request when asked.
enum ChatCommand {
    static func run(arguments: [String]) async throws {
        let options = try ChatOptions(arguments: arguments)
        if options.help { print(ChatOptions.usage); return }
        // The Braus support folder, `BRAUS_APP_SUPPORT_DIR` when set.
        let support = KnowledgeLocation.support()
        let history = options.historyDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? support.appendingPathComponent("Conversations", isDirectory: true)
        let store = try ConversationStore(directory: history)
        let saved = try store.list()
        if options.list {
            for item in saved { print("\(item.id.uuidString)  \(item.provider.rawValue)  \(item.model ?? "default")  \(item.title)") }
            if saved.isEmpty { print("No saved conversations.") }
            return
        }
        if let script = options.script {
            try await runScript(at: script, options: options, support: support, history: history, store: store)
            return
        }
        let interactive = isatty(STDIN_FILENO) != 0 && !options.once
        var conversation: Conversation?
        if let requested = options.resume {
            if requested == "last" {
                guard let last = saved.first else { throw ChatMenu.problem("No saved conversations.") }
                conversation = last
            } else {
                guard let id = UUID(uuidString: requested) else { throw ChatMenu.problem("--resume expects a UUID or last.") }
                conversation = try store.load(id)
            }
        } else if interactive && options.prompt == nil {
            conversation = try await ChatMenu.choose(saved)
        }
        if let existing = conversation {
            if let provider = options.provider, provider != existing.provider {
                throw ChatMenu.problem("A saved conversation belongs to \(existing.provider.rawValue). Start a new chat to change providers.")
            }
            if options.hasModelOption { conversation?.model = options.model }
        } else {
            let provider: ChatProvider
            if let selected = options.provider { provider = selected }
            else if interactive { provider = try await ChatMenu.provider() }
            else { throw ChatMenu.problem("Use --provider claude|codex for noninteractive chat.") }
            let model: String?
            if options.hasModelOption { model = options.model }
            else if interactive { model = try await ChatMenu.model(provider) }
            else { model = nil }
            conversation = Conversation(provider: provider, model: model)
        }
        guard let selected = conversation, let executable = ChatMenu.executable(selected.provider.rawValue) else {
            throw ChatMenu.problem("The selected provider CLI is not installed or is missing from PATH.")
        }
        let lease = try store.lease(selected.id)
        let hostLease = try hostLease(support)
        defer { withExtendedLifetime((lease, hostLease)) {} }
        let transcript = ChatTranscript(conversation: selected, store: store)
        try transcript.save()
        let session = try ChatSession(options: options, history: history, executable: executable)
        try await closing(session) {
            session.adopt(transcript)
            try await session.start()
            defer { session.stop() }
            print("\nBraus chat · \(selected.provider.displayName) · \(selected.model ?? "provider default")")
            print("Conversation: \(selected.id.uuidString)")
            if !selected.entries.isEmpty {
                print("Resuming saved context; application state will be observed again.")
                for entry in selected.entries.filter({ $0.kind == .user || $0.kind == .assistant }).suffix(4) {
                    print("\(entry.kind.rawValue) › \(entry.text.prefix(400))")
                }
            }
            print("/help for commands. Ctrl+C stops and releases the Seat.\n")
            try await preflight(options, session, evidence: nil)
            var next = options.prompt
            do {
                while true {
                    let line: String?
                    if let pending = next { line = pending; next = nil }
                    else if interactive { line = await ChatMenu.read("You › ") }
                    else { break }
                    guard let line else { break }
                    let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if message.isEmpty { continue }
                    if message == "/quit" || message == "/exit" { break }
                    if message == "/help" { print(ChatOptions.usage); continue }
                    if message == "/model" {
                        transcript.conversation.model = try await ChatMenu.model(selected.provider)
                        try transcript.save()
                        continue
                    }
                    if message == "/release" {
                        await session.tools.session.close()
                        try transcript.append(.tool, "User released the Seat. Any previous session ID is now stale.")
                        print("Seat released.")
                        continue
                    }
                    if message == "/status" {
                        let result = try await session.tools.call("status", .object([:]))
                        print(ChatScript.text(ChatScript.payload(of: result)))
                        continue
                    }
                    if message == "/memory" {
                        // The archive this process records into and the Recall it runs, as the process resolved them.
                        let result = try await session.tools.call("memory_task", .object(["operation": .string("status")]))
                        print(ChatScript.text(ChatScript.payload(of: result)))
                        continue
                    }
                    if message.hasPrefix("/") { print("Unknown command. Use /help."); continue }
                    try transcript.append(.user, message)
                    do {
                        try await session.turn(message)
                    } catch {
                        if let shutdown = session.shutdown { await shutdown.value; return }
                        await session.releaseSeat()
                        try transcript.append(.error, error.localizedDescription)
                        print("Chat error: \(transcript.shown(error.localizedDescription))")
                        if !interactive { throw turnFailure(error, shownBy: transcript) }
                    }
                    if options.once { break }
                }
                await session.releaseSeat()
                try transcript.save()
                await session.finish()
            } catch {
                if let shutdown = session.shutdown { await shutdown.value; return }
                await session.releaseSeat()
                throw error
            }
        }
    }

    /// Runs the requests of a script file, one new conversation each, on one archive and one host: the Seat and the
    /// application session are released between requests, so each starts from the applications as they are, with the
    /// knowledge the earlier ones left in the memory. A failed request stops the script unless `--continue`; the
    /// evidence folder, when asked, keeps every request's conversation, tasks and diagnoses.
    private static func runScript(at path: String, options: ChatOptions, support: URL, history: URL,
                                  store: ConversationStore) async throws {
        guard let provider = options.provider else { throw ChatMenu.problem("--script needs --provider claude|codex.") }
        guard let executable = ChatMenu.executable(provider.rawValue) else {
            throw ChatMenu.problem("The \(provider.rawValue) CLI is not installed or is missing from PATH.")
        }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let requests = ChatScript.requests(in: try String(contentsOf: file, encoding: .utf8))
        guard !requests.isEmpty else {
            throw ChatMenu.problem("\(file.path) holds no request: blocks of lines separated by empty lines, # for a comment.")
        }
        let hostLease = try hostLease(support)
        defer { withExtendedLifetime(hostLease) {} }
        let session = try ChatSession(options: options, history: history, executable: executable)
        try await closing(session) {
            try await session.start()
            defer { session.stop() }
            let evidence = try options.evidence.map { try ChatEvidence(directory: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)) }
            let archive = session.knowledge.appendingPathComponent("memory.sqlite")
            print("\nBraus chat script · \(provider.displayName) · \(options.hasModelOption ? (options.model ?? "provider default") : "provider default")"
                  + " · \(requests.count) requests · archive \(archive.path)"
                  + (evidence.map { " · evidence \($0.directory.path)" } ?? ""))
            try await preflight(options, session, evidence: evidence)
            // A stop by signal closes the task it cut and writes that request's evidence: no one is there to resume it.
            session.closesTaskOnStop = true
            var failed = 0
            var providerFailed = false
            // The conversation of the request before, which a `>` request continues; its lease lives as long as it may.
            var previous: (transcript: ChatTranscript, lease: ConversationLease)?
            for (index, request) in requests.enumerated() {
                let number = index + 1
                let transcript: ChatTranscript
                if request.continuesPrevious, let earlier = previous {
                    transcript = earlier.transcript
                    print("\n[\(number)/\(requests.count)] continues conversation \(transcript.conversation.id.uuidString)")
                } else {
                    let conversation = Conversation(provider: provider, model: options.hasModelOption ? options.model : nil)
                    let lease = try store.lease(conversation.id)
                    transcript = ChatTranscript(conversation: conversation, store: store)
                    try transcript.save()
                    session.adopt(transcript)
                    previous = (transcript, lease)
                    print("\n[\(number)/\(requests.count)] conversation \(conversation.id.uuidString)")
                }
                print("You › \(request.text)")
                try transcript.append(.user, request.text)
                transcript.beginRequest()
                let started = Date()
                // The agent's own calls, before Braus's calls of its own (a status, an abandoning end) are added.
                var calls: Int { transcript.conversation.entries.filter { $0.kind == .tool && $0.text.hasPrefix("→ ") }.count }
                session.interruption = { [evidence] signal, closed, agentEntries in
                    guard let evidence else { return }
                    let flushed = await MemoryService.shared(for: session.knowledge).flush(within: .seconds(2))
                    do {
                        try evidence.record(number: number, request: request.text, continues: request.continuesPrevious,
                                            transcript: transcript, started: started, ended: Date(), failure: nil, signal: signal,
                                            abandonment: closed, toolCalls: calls, agentEntries: agentEntries,
                                            memoryFlushed: flushed, archive: archive)
                    } catch {
                        fputs("braus: evidence of the stopped request not written: \(error)\n", stderr)
                    }
                }
                var failure: (any Error)?
                do {
                    try await session.turn(request.text)
                } catch {
                    if let shutdown = session.shutdown { await shutdown.value; return }
                    failure = error
                    try transcript.append(.error, error.localizedDescription)
                    print("Chat error: \(transcript.shown(error.localizedDescription))")
                }
                let agentCalls = calls
                let agentEntries = transcript.conversation.entries.count
                await session.releaseSeat()
                // A completed task the agent left uninterpreted, even after its reminder, is interpreted by Braus from its goal
                // and the phases already known: unattended, it was lost (review I1, BUG-11).
                var brausInterpreted: String?
                if let left = await session.tools.interpretLeftCandidate() {
                    brausInterpreted = left.candidate
                    let line = "Braus interpreted candidate \(left.candidate) itself: the agent left it uninterpreted."
                    print(line)
                    try transcript.append(.tool, line)
                }
                // A task the conversation left open would block the next conversation's own: unless the next request continues
                // this conversation, and the script goes on to it, it is closed as abandoned now, and said in the transcript.
                let goesOn = failure == nil || options.continueOnError
                var abandonment: ChatSession.Abandonment?
                if !(goesOn && requests.indices.contains(index + 1) && requests[index + 1].continuesPrevious),
                   let closed = await session.abandonOpenTask() {
                    abandonment = closed
                    let line = ChatSession.line(for: closed)
                    print(line)
                    try transcript.append(.tool, line)
                }
                try transcript.save()
                let ended = Date()
                if let evidence {
                    // What the turn recorded reaches the archive before its diagnosis is read.
                    let flushed = await MemoryService.shared(for: session.knowledge).flush(within: .seconds(15))
                    try evidence.record(number: number, request: request.text, continues: request.continuesPrevious, transcript: transcript,
                                        started: started, ended: ended, failure: failure, abandonment: abandonment,
                                        brausInterpreted: brausInterpreted, toolCalls: agentCalls, agentEntries: agentEntries,
                                        memoryFlushed: flushed, archive: archive)
                }
                session.interruption = nil
                print("[\(number)/\(requests.count)] \(failure == nil ? "done" : "failed") in \(Int(ended.timeIntervalSince(started))) s")
                if let failure {
                    failed += 1
                    providerFailed = providerFailed || failure is ProviderFailure
                    if !options.continueOnError {
                        throw ScriptStop(message: "Request \(number) of \(requests.count) failed; the script stops here (--continue goes on).",
                                         provider: failure is ProviderFailure)
                    }
                }
            }
            withExtendedLifetime(previous) {}
            await session.finish()
            print("\nscript done: \(requests.count) requests, \(failed) failed" + (evidence.map { "; evidence in \($0.directory.path)" } ?? ""))
            if failed > 0 { throw ScriptStop(message: "\(failed) of \(requests.count) requests failed.", provider: providerFailed) }
        }
    }

    /// Runs `body` with `session`, then finishes the session however `body` ended, a throw included: its application
    /// session and its Chrome are closed, and awaited, before the command returns.
    private static func closing(_ session: ChatSession, _ body: () async throws -> Void) async throws {
        do { try await body() } catch {
            await session.finish()
            throw error
        }
        await session.finish()
    }

    /// TurnFailure is a turn's error as it leaves a chat that stops on it (`--once`, a chat with no terminal): its text
    /// withheld as the transcript withholds it, so the process's last line holds no declared secret, with the
    /// provider's kind when the provider failed. The process still exits nonzero.
    struct TurnFailure: Error, LocalizedError, CustomStringConvertible {
        let message: String
        var errorDescription: String? { message }
        var description: String { message }
    }

    /// The `TurnFailure` of `error`, its text as `transcript` shows it.
    static func turnFailure(_ error: any Error, shownBy transcript: ChatTranscript) -> TurnFailure {
        let shown = transcript.shown(error.localizedDescription)
        guard let provider = error as? ProviderFailure else { return TurnFailure(message: shown) }
        return TurnFailure(message: "the provider failed (\(provider.kind.rawValue)): \(shown)")
    }

    /// ScriptStop is a script that ended on a failed request. The process exits with 3 when the provider failed (its
    /// kind is in the request's `summary.json`): a run of many tasks stops on it without reading the message.
    struct ScriptStop: Error, LocalizedError {
        let message: String
        let provider: Bool

        var errorDescription: String? { message }
        var exitStatus: Int32 { provider ? 3 : 1 }
    }

    /// Compares what this process answers to `memory_task status` with the identity a preflight file expects, before
    /// any turn; the answer and the verdict go to the evidence when there is one. A difference stops the chat before
    /// it touches anything.
    private static func preflight(_ options: ChatOptions, _ session: ChatSession, evidence: ChatEvidence?) async throws {
        guard let path = options.preflight else { return }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        let found = ChatScript.payload(of: try await session.tools.call("memory_task", .object(["operation": .string("status")])))
        let differences = ChatScript.differences(expected: expected, found: found)
        try evidence?.preflight(found: found, differences: differences)
        print("preflight: " + (differences.isEmpty ? "the process matches \(file.path)" : "\(differences.count) differences from \(file.path)"))
        for difference in differences { print("  \(difference)") }
        if !differences.isEmpty { throw ChatMenu.problem("The preflight does not match: nothing was run.") }
    }

    /// One CLI chat host at a time owns the Driver. Provider turn subprocesses share that owner.
    private static func hostLease(_ support: URL) throws -> ConversationLease {
        let hostStore = try ConversationStore(directory: support.appendingPathComponent("ChatHost"))
        return try hostStore.lease(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
    }
}
