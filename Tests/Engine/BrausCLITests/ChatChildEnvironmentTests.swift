import Foundation
import TestScratch
import Testing

@MainActor
@Suite("Chat child environment", .timeLimit(.minutes(1)))
struct ChatChildEnvironmentTests {
    static let names = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                        "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "EXPLICIT_CREDENTIAL"]

    @Test(arguments: ["claude", "codex"])
    func inheritedCredentialsAreRemoved(provider: String) async throws {
        let result = try await ChatChildProcess.run(provider: provider)
        #expect(result.output.contains("present:[]"))
        #expect(result.status == 0)
        #expect(!result.output.contains(ChatChildProcess.fakeValue))
    }
    @Test(arguments: ["claude", "codex"])
    func onlyTheExplicitVariableReachesTheChild(provider: String) async throws {
        let result = try await ChatChildProcess.run(provider: provider, options: ["--pass-env", "EXPLICIT_CREDENTIAL"])
        #expect(result.status == 0)
        #expect(result.output.contains("present:[\"EXPLICIT_CREDENTIAL\"]"))
        #expect(!result.output.contains(ChatChildProcess.fakeValue))
    }

    @Test(arguments: ["claude", "codex"])
    func aMissingNamedVariableAddsNothing(provider: String) async throws {
        let result = try await ChatChildProcess.run(provider: provider, options: ["--pass-env", "ABSENT"])
        #expect(result.status == 0)
        #expect(result.output.contains("present:[]"))
    }
}

/// ChatChildProcess runs the built chat with a synthetic home and provider, without desktop actions or accounts.
@MainActor
enum ChatChildProcess {
    static let fakeValue = "FAKE-CHILD-CREDENTIAL-Q7z9"

    static func run(provider: String, options: [String] = [], messages: String? = nil) async throws
        -> (output: String, status: Int32, arguments: [[String]]) {
        let root = URL.temporaryDirectory.appending(path: "braus-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error) }
        }
        let script = root.appending(path: provider)
        let names = String(decoding: try JSONEncoder().encode(ChatChildEnvironmentTests.names), as: UTF8.self)
        let body = """
        #!/usr/bin/python3
        import json, os, sys
        root = os.path.dirname(os.path.realpath(__file__))
        args = sys.argv[1:]
        with open(os.path.join(root, 'arguments.jsonl'), 'a') as file:
            file.write(json.dumps(args) + '\\n')
        sys.stdin.read()
        names = \(names)
        present = sorted(name for name in names if name in os.environ)
        text = 'present:' + json.dumps(present, separators=(',', ':'))
        if '\(provider)' == 'claude':
            print(json.dumps({'type':'system','subtype':'init','session_id':'s1'}))
            print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':text}]}}))
            print(json.dumps({'type':'result','is_error':False,'result':text,'session_id':'s1'}))
        else:
            print(json.dumps({'type':'thread.started','thread_id':'s1'}))
            print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':text}}))
            print(json.dumps({'type':'turn.completed'}))
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = try builtExecutable("braus")
        if let messages { try Data(messages.utf8).write(to: root.appending(path: "requests.txt")) }
        process.arguments = ["chat", "--provider", provider, "--history-dir", root.appending(path: "history").path,
                             "--knowledge", root.appending(path: "knowledge").path]
            + (messages == nil ? ["--once", "Reply briefly"] : ["--script", root.appending(path: "requests.txt").path]) + options
        var environment = ["HOME": root.path, "TMPDIR": root.path + "/", "PATH": root.path + ":/usr/bin:/bin",
                           "LANG": "en_US.UTF-8", "BRAUS_APP_SUPPORT_DIR": root.appending(path: "support").path]
        for name in ChatChildEnvironmentTests.names { environment[name] = fakeValue }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        let lines = Lines()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        lines.follow(output.fileHandleForReading)
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(20)
        while process.isRunning || !lines.finished {
            try #require(ContinuousClock.now < deadline, "Synthetic chat did not finish")
            try await Task.sleep(for: .milliseconds(10))
        }
        let log = root.appending(path: "arguments.jsonl")
        let arguments: [[String]]
        if FileManager.default.fileExists(atPath: log.path) {
            arguments = try Data(contentsOf: log).split(separator: 10).map {
                try JSONDecoder().decode([String].self, from: Data($0))
            }
        } else { arguments = [] }
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let file = root.appending(path: path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                #expect(!(try Data(contentsOf: file)).contains(Data(fakeValue.utf8)), "Credential persisted in \(path)")
            }
        }
        return (lines.text, process.terminationStatus, arguments)
    }
    private static func builtExecutable(_ name: String) throws -> URL {
        if let path = ProcessInfo.processInfo.environment["BRAUS_TEST_BRAUS"] {
            return URL(filePath: path)
        }
        var root = URL(filePath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        for products in [".build/debug", ".build/out/Products/Debug"] {
            let executable = root.appending(path: products).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
        }
        throw CocoaError(.fileNoSuchFile)
    }

}
