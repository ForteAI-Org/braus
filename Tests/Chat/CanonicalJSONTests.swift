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
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let accepted = AsyncThrowingStream<NWConnection, any Error>.makeStream()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            accepted.continuation.yield(connection)
        }
        defer { listener.cancel() }
        let port: NWEndpoint.Port = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        if let port = listener.port { continuation.resume(returning: port) }
                        else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                listener.start(queue: .global())
            }
        } onCancel: { listener.cancel() }
        let sender = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        let starting = Task {
            do { try await sender.start() }
            catch {
                accepted.continuation.finish(throwing: error)
                throw error
            }
        }
        defer { sender.close(); starting.cancel(); accepted.continuation.finish() }
        var iterator = accepted.stream.makeAsyncIterator()
        let receiver = try #require(try await iterator.next())
        defer { receiver.cancel() }
        try await starting.value
        for rotation in 0..<20 {
            let value = Self.value(rotation: rotation)
            try await sender.write(value)
            var bytes = Data()
            while bytes.last != 10 {
                let chunk: Data = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        receiver.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let data, !data.isEmpty { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                        }
                    }
                } onCancel: { receiver.cancel() }
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
        process.currentDirectoryURL = root
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
            let executable = URL(filePath: path)
            try #require(FileManager.default.isExecutableFile(atPath: executable.path), "\(path) is not executable")
            return executable
        }
        var directory = Bundle(for: BundleAnchor.self).bundleURL
        for _ in 0..<6 {
            let executable = directory.appending(path: name)
            if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: directory.appending(path: name).path])
    }

    private final class BundleAnchor {}

    @Test
    func bridgeExecutableIsAvailable() throws {
        _ = try Self.builtExecutable("braus-bridge")
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
