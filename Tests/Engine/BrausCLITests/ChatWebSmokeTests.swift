import ChatCore
import FileConversations
import Foundation
import LocalMCP
import TestScratch
import Testing

/// One `braus` command line in a process of its own, as a person runs it, for P10's smokes. Its `claude` is a stand-in
/// on a temporary `PATH`: it starts the bridge `--mcp-config` names, as Claude Code does, makes one call through it,
/// and answers. The process runs with a temporary `HOME`, `PATH` and `BRAUS_APP_SUPPORT_DIR`, and explicit history
/// and knowledge folders, all under `root`: nothing of the person's is read or written.
///
/// It is stopped only by the PID this test started it with (SIGTERM, then SIGKILL after 5 s, and reaped), and a Chrome
/// left on the chat's own profile under `root` only by the PIDs `ps` gives for that profile, which no other Chrome
/// names; then the caller stops its server, then `remove` removes `root`.
@MainActor
final class BrausRun {

    /// The stand-in Claude Code. The prompt's first word says what it does through the bridge:
    /// `open <url>` asks `open_session` for the URL; `call <tool> <text> <file>` calls the tool with `text` and writes
    /// the bridge's whole answer to `file`.
    static let claude = """
        #!/usr/bin/python3
        import json, subprocess, sys
        args = sys.argv[1:]
        words = sys.stdin.read().split()
        server = json.loads(args[args.index('--mcp-config') + 1])['mcpServers']['braus']
        bridge = subprocess.Popen([server['command']] + server['args'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        def ask(number, method, params):
            request = {'jsonrpc': '2.0', 'id': number, 'method': method, 'params': params}
            bridge.stdin.write((json.dumps(request) + '\\n').encode())
            bridge.stdin.flush()
            while True:
                line = bridge.stdout.readline()
                if not line:
                    return None
                answer = json.loads(line)
                if answer.get('id') == number:
                    return answer
        ask(1, 'initialize', {'protocolVersion': '2025-11-25'})
        if words[0] == 'open':
            answer = ask(2, 'tools/call', {'name': 'open_session', 'arguments': {'app': words[-1]}})
        else:
            answer = ask(2, 'tools/call', {'name': words[1], 'arguments': {'text': words[2]}})
            with open(words[3], 'w') as file:
                json.dump(answer, file)
        bridge.stdin.close()
        bridge.wait(timeout=10)
        def say(event):
            event['session_id'] = 's1'
            print(json.dumps(event), flush=True)
        say({'type': 'system', 'subtype': 'init', 'model': 'claude-sonnet-5'})
        text = 'done' if answer and 'result' in answer else 'not done'
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': text}]}})
        say({'type': 'result', 'is_error': False, 'result': text})

        """

    let root = URL.temporaryDirectory.appending(path: "braus-chat-run-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
    var bin: URL { root.appending(path: "bin") }
    var home: URL { root.appending(path: "home") }
    var history: URL { root.appending(path: "History") }
    var knowledge: URL { root.appending(path: "Knowledge") }
    var support: URL { root.appending(path: "support") }
    /// The chat's own Chrome profile, under its history folder.
    var profile: String { history.appending(path: "Chrome").path }
    private let process = Process()

    init() throws {
        for directory in [bin, home, history, knowledge, support] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(Self.claude.utf8).write(to: bin.appending(path: "claude"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: bin.appending(path: "claude").path)
    }

    /// A class of this test target, whose bundle is the test bundle.
    final class InThisBundle {}

    /// The built `braus`, beside this test bundle.
    static func braus() throws -> URL {
        let built = Bundle(for: InThisBundle.self).bundleURL.deletingLastPathComponent().appending(path: "braus")
        try #require(FileManager.default.isExecutableFile(atPath: built.path), "build braus: \(built.path)")
        return built
    }

    /// Runs `braus chat` with `arguments` and the explicit history and knowledge folders, for at most 90 s: its exit
    /// status and what it printed.
    func chat(_ arguments: [String]) async throws -> (status: Int32, said: String) {
        process.executableURL = try Self.braus()
        process.arguments = ["chat"] + arguments + ["--history-dir", history.path, "--knowledge", knowledge.path]
        process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin", "LANG": "en_US.UTF-8",
                               "BRAUS_APP_SUPPORT_DIR": support.path, "TMPDIR": root.path + "/"]
        process.currentDirectoryURL = home
        let output = root.appending(path: "chat.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let log = try FileHandle(forWritingTo: output)
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(90)
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if await stopChat() { Issue.record("braus chat outlived 90 s; stopped by its PID") }
        try? log.close()
        return (process.terminationStatus, (try? String(contentsOf: output, encoding: .utf8)) ?? "")
    }

    /// Ends the chat process if it still runs, by its own PID: SIGTERM, 5 s, then SIGKILL, and reaps it. Whether it
    /// had to.
    func stopChat() async -> Bool {
        guard process.processIdentifier > 0, process.isRunning else { return false }
        for number in [SIGTERM, SIGKILL] where process.isRunning {
            kill(process.processIdentifier, number)
            let bound = ContinuousClock.now + .seconds(5)
            while process.isRunning, ContinuousClock.now < bound { try? await Task.sleep(for: .milliseconds(50)) }
        }
        process.waitUntilExit()
        return true
    }

    /// The `ps` lines (PID, command) that name `path`.
    static func processes(naming path: String) -> [String] {
        let ps = Process(), output = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        ps.standardOutput = output
        guard (try? ps.run()) != nil else { return ["ps failed"] }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return text.split(separator: "\n").map(String.init).filter { $0.contains(path) }
    }

    /// Whether no process names `path` any more, within 10 s.
    static func gone(_ path: String) async -> Bool {
        (try? await BridgeProcess.eventually { processes(naming: path).isEmpty }) ?? false
    }

    /// Stops what the chat left running that names `path` under `root` (its Chrome's profile, a copied
    /// program), by the PIDs `ps` gives for that path: never another process.
    func stop(naming path: String) {
        guard path.contains(root.path) else { return }
        for line in Self.processes(naming: path) {
            if let pid = pid_t(line.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) { kill(pid, SIGKILL) }
        }
    }

    /// The chat stopped, then what it left under `root`, on every path, before the caller's server stops.
    func stopProcesses() async {
        _ = await stopChat()
        stop(naming: "--user-data-dir=" + profile)
        stop(naming: root.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// The text of each saved `.tool` record that starts with `prefix`, from the saved conversations only, never the
    /// rest of the history folder (the chat's Chrome profile and its cache are there too).
    func records(_ prefix: String) throws -> [String] {
        try ConversationStore(directory: history).list().flatMap(\.entries)
            .filter { $0.kind == .tool && $0.text.hasPrefix(prefix) }.map(\.text)
    }

    /// Prints `name` and `result` as one JSON line, for whoever reads the log.
    static func report(_ name: String, _ result: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(name + " " + String(decoding: json, as: UTF8.self))
    }
}

/// P10's one real smoke of the web route, through the command line: `braus chat --once --provider claude --channels
/// web --chrome <wrapper>`. The stand-in asks `open_session` for the page this test serves on 127.0.0.1; the chat opens
/// it in its own headless Chrome, on its profile under the history folder; the test reads the page's text back from
/// the call's saved record, and the server's count of requests.
///
/// The `--chrome` wrapper runs `BRAUS_WEB_LIVE_CHROME` (Chrome for Testing) with `--use-mock-keychain`, so the
/// throwaway profile touches no keychain; the product passes no such flag. Opt in with `BRAUS_WEB_LIVE_TESTS=1` and
/// `BRAUS_WEB_LIVE_CHROME` (absolute path). Loopback only: no network or account.
@MainActor
@Suite("P10: braus chat --channels web opens a local page in its own Chrome (live, opt-in)", .serialized,
       .timeLimit(.minutes(3)),
       .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1"
                && ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_CHROME"]?.hasPrefix("/") == true))
struct ChatWebSmokeTests {

    @Test("braus chat --once --channels web: the page served on 127.0.0.1 opens in the chat's own Chrome, its text in the call's saved record, and the Chrome is gone when the chat ends")
    func aLocalPageThroughTheCommandLine() async throws {
        let chrome = try #require(ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_CHROME"])
        let run = try BrausRun()
        let wrapper = run.root.appending(path: "chrome")
        try Data("#!/bin/sh\nexec \"\(chrome)\" --use-mock-keychain \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let oracle = "braus-p10-oracle-\(UUID().uuidString.prefix(8))"
        let server = try await FixtureHTTPServer.start(
            page: "<!doctype html><html><head><title>P10</title></head><body><h1>\(oracle)</h1></body></html>")
        do {
            let (status, said) = try await run.chat(["--once", "--provider", "claude", "--channels", "web",
                                                     "--chrome", wrapper.path, "open \(server.url.absoluteString)"])
            #expect(status == 0, "braus chat: \(said.suffix(1500))")
            let records = try run.records("← open_session")
            let record = records.first { !$0.hasPrefix("← open_session error") && $0.contains(oracle) }
            #expect(record != nil,
                    "the page's text, read from the DOM, in the call's saved record: \(said.suffix(800))")
            let served = await server.counts["/"] ?? 0
            #expect(served >= 1, "the page came from this test's server")
            let profileMade = FileManager.default.fileExists(atPath: run.profile)
            #expect(profileMade, "the chat's own profile, under its history folder")
            let closed = await BrausRun.gone(run.profile)
            #expect(closed, "no Chrome runs on the chat's profile once the chat ended")
            try BrausRun.report("P10_SMOKE_RESULT", [
                "oracle": oracle, "open_session_record": record ?? records.first ?? "",
                "oracle_in_record": record != nil,
                "site_requests": served, "cli_exit": Int(status), "profile_created": profileMade,
                "profile_chrome_closed": closed,
            ])
        } catch {
            await run.stopProcesses()
            await server.stop()
            run.remove()
            throw error
        }
        await run.stopProcesses()
        await server.stop()
        run.remove()
    }
}
