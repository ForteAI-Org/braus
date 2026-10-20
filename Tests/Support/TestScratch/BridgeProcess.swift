//
//  BridgeProcess.swift
//  Braus
//

import Darwin
import Foundation
import LocalMCP

/// A bridge a test started, `<executable> mcp-bridge --connection <file>` (`braus-bridge`, or `braus`: the same
/// words): its process and PID, its input, and the lines it wrote out and to standard error. A test speaks JSONL to
/// it as a command line's child does, and ends it only by the PID it started it with.
@MainActor
public final class BridgeProcess {

    /// How long one wait may last: an answer, the bridge's exit.
    public nonisolated static let patience: Duration = .seconds(10)

    /// No answer to a request within `patience`, with what the bridge wrote to standard error.
    public struct NoAnswer: Error, CustomStringConvertible {
        public let description: String
    }

    /// Waits until `condition` holds, for `patience` at most, cancellation honoured: false when it never did.
    public static func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + patience
        while !condition() {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    public enum Ending: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)
    }

    public let index: Int
    public let pid: pid_t
    private let process: Process
    private let input: FileHandle
    private let output = Lines()
    private let diagnostics = Lines()
    private var inputClosed = false
    private var requestID = 0

    /// Starts `executable mcp-bridge --connection <connection>` with a home and temporary folder of its own under
    /// `root`, and no variable of this process.
    public init(executable: URL, connection: URL, root: URL, index: Int) throws {
        let home = root.appending(path: "bridge-\(index)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp-bridge", "--connection", connection.path]
        process.environment = ["HOME": home.path, "TMPDIR": home.path + "/", "PATH": "/usr/bin:/bin",
                               "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = home
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Writing to a bridge that already ended fails with an error rather than raising SIGPIPE in the test.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        self.index = index
        self.process = process
        self.pid = process.processIdentifier
        self.input = stdin.fileHandleForWriting
        output.follow(stdout.fileHandleForReading)
        diagnostics.follow(stderr.fileHandleForReading)
    }

    /// What the bridge wrote to standard error.
    public var errors: String { diagnostics.text }

    /// Writes one JSON-RPC request line; its id.
    public func send(_ method: String, _ params: JSONValue = .object([:])) throws -> Int {
        requestID += 1
        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(requestID)), "method": .string(method), "params": params,
        ])
        var data = try JSONEncoder().encode(request)
        data.append(10)
        try input.write(contentsOf: data)
        return requestID
    }

    /// The answer to request `id` among the lines the bridge wrote so far; nil when there is none.
    public func answer(_ id: Int) -> JSONValue? {
        output.lines.lazy
            .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            .first { $0["id"] == .number(Double(id)) }
    }

    /// One request and its answer, within `patience`; `NoAnswer` when none came.
    public func ask(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        let id = try send(method, params)
        var found: JSONValue?
        _ = try await Self.eventually {
            found = answer(id)
            return found != nil
        }
        guard let found else { throw NoAnswer(description: "no answer to \(method) from bridge \(index): \(errors)") }
        return found
    }


    /// Ends the bridge's input, as a client that goes.
    public func closeInput() throws {
        guard !inputClosed else { return }
        inputClosed = true
        try input.close()
    }

    /// How the bridge ended, once it did and both its pipes reached their end, within `patience`; nil before.
    public func ending() async throws -> Ending? {
        guard try await Self.eventually({
            !process.isRunning && output.finished && diagnostics.finished
        }) else { return nil }
        return process.terminationReason == .uncaughtSignal
            ? .signalled(process.terminationStatus) : .exited(process.terminationStatus)
    }

    /// Sends `number` to the PID this test started the bridge with, only while that process runs.
    public func terminate(with number: Int32) {
        guard process.isRunning, pid > 0 else { return }
        Darwin.kill(pid, number)
    }

    /// Stops the bridge if it still runs, by its PID: SIGTERM, then SIGKILL after 5 s. Whether it had to.
    public func stop() async -> Bool {
        defer { try? closeInput() }
        guard process.isRunning else { return false }
        for number in [SIGTERM, SIGKILL] where process.isRunning {
            terminate(with: number)
            let deadline = ContinuousClock.now + .seconds(5)
            while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
        return true
    }
}

/// The lines a pipe carries, read as they come on the pipe's own queue.
public final class Lines: @unchecked Sendable {

    public init() {}
    private let lock = NSLock()
    private var pending = Data()
    private var complete: [String] = []
    private var ended = false

    public func follow(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            lock.withLock {
                if data.isEmpty { ended = true }
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    complete.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
        }
    }

    public var lines: [String] { lock.withLock { complete } }

    /// Whether the pipe reached its end: every line it carried is in.
    public var finished: Bool { lock.withLock { ended } }

    public var text: String {
        lock.withLock { (complete + [String(decoding: pending, as: UTF8.self)]).joined(separator: "\n") }
    }
}
