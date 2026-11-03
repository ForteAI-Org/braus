import Darwin
import Foundation
import Testing
@testable import ModelTransports

@Suite struct AnthropicHostTests {
    @Test(arguments: ["https://api.anthropic.com", "https://api.anthropic.com/"])
    func defaultOriginAcceptsTrailingSlash(_ host: String) throws {
        let client = AnthropicClient(model: "test-model", effort: .high, apiKey: "fake-key", host: host)
        #expect(try client.endpointURL().absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test(arguments: ["https://example.com", "http://api.anthropic.com", "https://api.anthropic.com:8443",
                      "https://api.anthropic.com/other", "https://user@api.anthropic.com/"])
    func otherDestinationsAreRefused(_ host: String) {
        let client = AnthropicClient(model: "test-model", effort: .high, apiKey: "fake-key", host: host)
        #expect(throws: (any Error).self) { try client.endpointURL() }
    }

    @Test func aRealRequestReachesOnlyTheConfiguredLoopback() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try #require(listen(listener, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try #require(withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        } == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        try #require(setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        let received = Task.detached { () throws -> String in
            var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            try #require(poll(&readiness, 1, 5000) == 1)
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(connection) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            try #require(setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                   socklen_t(MemoryLayout<timeval>.size)) == 0)
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let capacity = buffer.count
                let size = recv(connection, &buffer, capacity, 0)
                guard size > 0 else { throw POSIXError(.EIO) }
                request.append(contentsOf: buffer.prefix(size))
                if let boundary = request.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(decoding: request[..<boundary.lowerBound], as: UTF8.self)
                    let line = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    let count = Int(line?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                    if request.count >= boundary.upperBound + count { break }
                }
            }
            let stream = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
                + "data: {\"type\":\"message_stop\"}\n\n"
            let response = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(stream.utf8.count)\r\nConnection: close\r\n\r\n" + stream).utf8)
            let written = response.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
            try #require(written == response.count)
            return String(decoding: request, as: UTF8.self)
        }
        let settings = ProviderSettings(anthropicAPIKey: "fake-key", anthropicHost: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")
        let transport = ModelSelection(provider: .anthropic, model: "test-model").transport(settings: settings)
        do {
            for try await _ in try transport.converse([TurnMessage(role: .user, text: "Hello")], timeout: 5) {}
            let request = try await received.value
            #expect(request.hasPrefix("POST /v1/messages HTTP/1.1"))
            #expect(request.lowercased().contains("x-api-key: fake-key"))
            #expect(request.contains("\"cache_control\":{\"type\":\"ephemeral\"}"))
        } catch let primary {
            do { _ = try await received.value }
            catch { Issue.record(error) }
            throw primary
        }
    }
}
