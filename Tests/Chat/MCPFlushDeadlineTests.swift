import Darwin
import Foundation
@testable import LocalMCP
import Testing

@MainActor
@Suite("MCP bounded response flushing", .serialized, .timeLimit(.minutes(1)))
struct MCPFlushDeadlineTests {
    enum FlushInterruption: CaseIterable, Equatable, Sendable { case deadline, cancellation, stop }

    @Test(arguments: FlushInterruption.allCases)
    func nonReadingClientCannotHoldShutdown(_ interruption: FlushInterruption) async throws {
        var called = false
        var closed = false
        let router = MCPRouter(tools: [.object(["name": .string("observe")])], instructions: nil) { _, _ in
            called = true
            return .string(String(repeating: "x", count: 16 * 1_024 * 1_024))
        }
        let host = LocalMCPHost(maximumConnections: 1) {
            MCPHostSession(router: router, cancelsOnDisconnect: false) { closed = true }
        }
        let endpoint = try await host.start()
        let client = try nonReadingClient(endpoint)
        defer { Darwin.close(client); host.stop() }
        let request: JSONValue = .object([
            "token": .string(endpoint.token), "message": .object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params": .object(["name": .string("observe"), "arguments": .object([:])])
            ])
        ])
        var data = try JSONEncoder().encode(request)
        data.append(10)
        try FileHandle(fileDescriptor: client, closeOnDealloc: false).write(contentsOf: data)
        while !called { await Task.yield() }
        await router.drain()
        var joining = false
        let began = ContinuousClock.now
        let shutdown = Task {
            joining = true
            await host.stopAndDrain(flushTimeout: interruption == .deadline ? .milliseconds(20) : .seconds(30))
        }
        while !joining { await Task.yield() }
        switch interruption {
        case .deadline: break
        case .cancellation: shutdown.cancel()
        case .stop: host.stop()
        }
        await shutdown.value
        #expect(closed)
        #expect(began.duration(to: .now) < .seconds(10))
        if interruption == .deadline {
            #expect(began.duration(to: .now) >= .milliseconds(20))
        }
    }

    private func nonReadingClient(_ endpoint: LocalConnection) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        do {
            var bytes: Int32 = 1_024
            let configured = setsockopt(
                descriptor, SOL_SOCKET, SO_RCVBUF, &bytes, socklen_t(MemoryLayout.size(ofValue: bytes))
            )
            try #require(configured == 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = endpoint.port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(connected == 0)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
