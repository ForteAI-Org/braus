import Foundation
@testable import LocalMCP
import Network
import TestScratch
import Testing

@MainActor
@Suite("Canonical JSON bytes", .timeLimit(.minutes(1)))
struct CanonicalJSONTests {
    static func value(rotation: Int) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for offset in 0..<30 {
            let index = (offset + rotation) % 30
            fields[String(format: "key%02d", index)] = .object([
                "z": .number(Double(index)), "a": .string("https://example.invalid/path")
            ])
        }
        return .object(fields)
    }

    static func expected(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    @Test
    func toolResultsHaveCanonicalBytes() throws {
        for rotation in 0..<20 {
            let value = Self.value(rotation: rotation)
            let text = try #require(MCPRouter.toolResult(value)["content"].array?.first?["text"].string)
            #expect(Data(text.utf8) == (try Self.expected(value)))
        }
    }

    @Test
    func channelWritesHaveCanonicalBytes() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = AsyncThrowingStream<NWConnection, any Error> { continuation in
            listener.newConnectionHandler = { continuation.yield($0) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { continuation.finish(throwing: error) }
                if case .cancelled = state { continuation.finish() }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while listener.port == nil {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        let port = try #require(listener.port)
        let sender = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        let starting = Task { try await sender.start() }
        var iterator = accepted.makeAsyncIterator()
        let receiver = try #require(try await iterator.next())
        receiver.start(queue: .global())
        defer { sender.close(); receiver.cancel() }
        try await starting.value
        for rotation in 0..<20 {
            let value = Self.value(rotation: rotation)
            try await sender.write(value)
            var bytes = Data()
            while bytes.last != 10 {
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    receiver.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                    }
                }
                bytes.append(chunk)
            }
            #expect(bytes == (try Self.expected(value)) + Data([10]))
        }
    }
    @Test
    func bridgeWritesHaveCanonicalBytes() async throws {
        let root = URL.temporaryDirectory.appending(path: "braus-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error) }
        }
        let router = MCPRouter(
            tools: [.object(["name": .string("echo")])], instructions: "Fixed instructions."
        ) { _, arguments in MCPRouter.toolResult(arguments) }
        let host = LocalMCPHost(router: router)
        let endpoint = try await host.start()
        defer { host.stop() }
        let file = root.appending(path: "connection.json")
        try JSONEncoder().encode(endpoint).write(to: file)
        let process = Process()
        process.executableURL = try Self.builtExecutable("braus-bridge")
        process.arguments = ["mcp-bridge", "--connection", file.path]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TMPDIR": root.path + "/"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let lines = Lines(), diagnostics = Lines()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        lines.follow(output.fileHandleForReading)
        diagnostics.follow(errors.fileHandleForReading)
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for rotation in 0..<20 {
            let request: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params": .object(["name": .string("echo"), "arguments": Self.value(rotation: rotation)])
            ])
            let expected = try #require(await router.handle(request))
            try input.fileHandleForWriting.write(contentsOf: Self.expected(request) + Data([10]))
            try #require(try await BridgeProcess.eventually { lines.lines.count > rotation }, "\(diagnostics.text)")
            #expect(Data(lines.lines[rotation].utf8) == (try Self.expected(expected)))
        }
        try input.fileHandleForWriting.close()
        try #require(try await BridgeProcess.eventually { !process.isRunning && lines.finished && diagnostics.finished })
        #expect(process.terminationStatus == 0)
    }

    private static func builtExecutable(_ name: String) throws -> URL {
        if let path = ProcessInfo.processInfo.environment["BRAUS_TEST_BRIDGE"] {
            return URL(filePath: path)
        }
        let executable = Bundle.module.bundleURL.deletingLastPathComponent().appending(path: name)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }

    @Test
    func theCanonicalEncoderIsFreshAndUsesBothFormattingRules() throws {
        let encoder = JSONValue.canonicalEncoder()
        #expect(encoder.outputFormatting == [.sortedKeys, .withoutEscapingSlashes])
        encoder.outputFormatting = []
        #expect(JSONValue.canonicalEncoder().outputFormatting == [.sortedKeys, .withoutEscapingSlashes])
        let value = Self.value(rotation: 11)
        #expect(try JSONValue.canonicalEncoder().encode(value) == Self.expected(value))
    }

}
