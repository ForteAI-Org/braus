//
//  ChromeProfileHubTests.swift
//  Braus
//

import Foundation
import Synchronization
import Testing
@testable import ChromeProfiles
@testable import WebDriver

/// The hub and its transport with fake extension instances on the hub's real Unix socket, in a temporary directory:
/// pairing and its persistence, refusals before anything is sent, routing to the chosen instance alone, answers
/// accepted only from the current link that owns them, closing only Braus's own tabs, and a revocation that stops
/// every later dispatch. No Chrome, no extension, no native host.
@Suite("Chrome profiles: hub and transport", .serialized)
struct ChromeProfileHubTests {

    /// FakeInstance is one extension instance as the native host relays it: a client of the hub's socket that
    /// records every line it receives and answers through `respond` (nil to stay silent).
    final class FakeInstance: Sendable {
        let descriptor: Int32
        private let lines = Mutex<[JSONValue]>([])
        private let respond: @Sendable (FakeInstance, JSONValue) -> Void

        init(socket path: String, respond: @escaping @Sendable (FakeInstance, JSONValue) -> Void = FakeInstance.chrome)
            throws {
            self.respond = respond
            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw ChromeProfileError.notRunning }
            let thread = Thread { [self] in
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                    if count <= 0 { break }
                    pending.append(contentsOf: buffer[0..<count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[pending.startIndex..<newline])
                        pending.removeSubrange(pending.startIndex...newline)
                        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                        lines.withLock { $0.append(message) }
                        respond(self, message)
                    }
                }
            }
            thread.start()
        }

        /// A Chrome that opens tab 7, closes what it is asked, and answers every DevTools command with `{}`.
        static let chrome: @Sendable (FakeInstance, JSONValue) -> Void = { instance, message in
            switch message["type"]?.stringValue {
                case "openTab":
                    instance.send(["type": "result", "requestId": message["requestId"] ?? .null, "ok": true,
                                   "tabId": 7])
                case "closeTab":
                    instance.send(["type": "result", "requestId": message["requestId"] ?? .null, "ok": true,
                                   "tabId": message["tabId"] ?? .null])
                case "cdp":
                    instance.send(["type": "cdpResult", "tabId": message["tabId"] ?? .null,
                                   "id": message["id"] ?? .null, "result": ["from": "fake"]])
                default:
                    break
            }
        }

        var received: [JSONValue] { lines.withLock { $0 } }

        func received(_ type: String) -> [JSONValue] { received.filter { $0["type"]?.stringValue == type } }

        func send(_ message: JSONValue) {
            guard var line = try? JSONEncoder().encode(message) else { return }
            line.append(0x0A)
            _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        }

        func hello(_ id: String, paired label: String?) {
            send(["type": "hello", "instanceId": .string(id), "paired": .bool(label != nil),
                  "label": label.map(JSONValue.string) ?? .null])
        }

        func disconnect() {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    /// The answers a transport gave, by command id.
    final class Answers: Sendable {
        let values = Mutex<[Int: JSONValue]>([:])
    }

    static func directory() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true).appending(path: "bcp-\(UUID().uuidString.prefix(8))",
                                                                   directoryHint: .isDirectory)
    }

    /// Waits until `condition` holds, for up to 5 s.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: Pairing

    @Test("only paired instances are listed, by the person's name, with their connection; pairings survive a relaunch")
    func registry() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = ChromeProfileHub(directory: directory)
        try hub.start()
        let alfa = try FakeInstance(socket: hub.socketPath)
        alfa.hello("A", paired: nil)
        let beta = try FakeInstance(socket: hub.socketPath)
        beta.hello("B", paired: "Lavoro")
        #expect(await Self.eventually { hub.profiles.map(\.label) == ["Lavoro"] }, "an unpaired instance is not listed")
        alfa.send(["type": "paired", "label": "Personale"])
        #expect(await Self.eventually { hub.profiles.map(\.label) == ["Lavoro", "Personale"] })
        #expect(hub.profiles.allSatisfy { $0.isConnected })
        beta.disconnect()
        #expect(await Self.eventually {
            hub.profiles == [ChromeProfile(instanceID: "B", label: "Lavoro", isConnected: false),
                             ChromeProfile(instanceID: "A", label: "Personale", isConnected: true)]
        }, "a disconnected profile stays listed, as disconnected")
        hub.stop()
        alfa.disconnect()

        let relaunched = ChromeProfileHub(directory: directory)
        #expect(relaunched.profiles.map(\.label) == ["Lavoro", "Personale"]
                && relaunched.profiles.allSatisfy { !$0.isConnected }, "the pairings come back, disconnected")
        try relaunched.start()
        let again = try FakeInstance(socket: relaunched.socketPath)
        again.hello("B", paired: nil)
        #expect(await Self.eventually { relaunched.profiles.map(\.label) == ["Personale"] },
                "an instance that says it is no longer paired was revoked meanwhile: forgotten")
        again.send(["type": "paired", "label": "Lavoro"])
        _ = await Self.eventually { relaunched.profiles.count == 2 }
        again.send(["type": "revoked"])
        #expect(await Self.eventually { relaunched.profiles.map(\.label) == ["Personale"] })
        relaunched.stop()
        #expect(ChromeProfileHub(directory: directory).profiles.map(\.label) == ["Personale"],
                "the revocation is saved")
        again.disconnect()
    }

    // MARK: Refusals and routing

    @Test("an unknown, revoked or disconnected profile is refused before anything is sent to any instance")
    func refusals() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = ChromeProfileHub(directory: directory)
        await #expect(throws: ChromeProfileError.notRunning) { try await hub.connect("A") }
        try hub.start()
        let alfa = try FakeInstance(socket: hub.socketPath)
        alfa.hello("A", paired: "Personale")
        _ = await Self.eventually { hub.profiles.count == 1 }
        await #expect(throws: ChromeProfileError.unknown(instanceID: "Z")) { try await hub.connect("Z") }
        alfa.disconnect()
        _ = await Self.eventually { hub.profiles.first?.isConnected == false }
        await #expect(throws: ChromeProfileError.disconnected(label: "Personale")) { try await hub.connect("A") }
        #expect(alfa.received.isEmpty, "nothing was sent to the instance")
        hub.stop()
    }

    @Test("a tab Braus opens in the chosen profile is driven through that instance alone")
    func routing() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = ChromeProfileHub(directory: directory)
        try hub.start()
        let alfa = try FakeInstance(socket: hub.socketPath)
        let beta = try FakeInstance(socket: hub.socketPath)
        alfa.hello("A", paired: "Personale")
        beta.hello("B", paired: "Lavoro")
        _ = await Self.eventually { hub.profiles.count == 2 }

        let browser = try await hub.connect("B")
        #expect(browser.product.contains("Lavoro") && !browser.ownsChrome)
        let page = try await browser.openPage(url: "https://example.invalid/")
        #expect(page.targetID == "tab-7" && page.sessionID == "tab-7")
        let answer = try await page.send("Runtime.evaluate", ["expression": "1"])
        #expect(answer["from"]?.stringValue == "fake")
        let cdp = beta.received("cdp")
        #expect(cdp.count == 1 && cdp[0]["method"]?.stringValue == "Runtime.evaluate" && cdp[0]["tabId"]?.intValue == 7)
        #expect(beta.received("openTab").first?["url"]?.stringValue == "https://example.invalid/")
        #expect(alfa.received.isEmpty, "the other profile's instance received nothing")
        await browser.close()
        hub.stop()
    }

    @Test("an answer from another instance is dropped, the request completes from its own link, a replaced link ends")
    func answersOnlyFromTheOwningLink() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = ChromeProfileHub(directory: directory)
        try hub.start()
        let silent: @Sendable (FakeInstance, JSONValue) -> Void = { _, _ in }
        let alfa = try FakeInstance(socket: hub.socketPath, respond: silent)
        let beta = try FakeInstance(socket: hub.socketPath, respond: silent)
        alfa.hello("A", paired: "Personale")
        beta.hello("B", paired: "Lavoro")
        _ = await Self.eventually { hub.profiles.count == 2 }

        let browser = try await hub.connect("A")
        let opening = Task { try await browser.openPage() }
        #expect(await Self.eventually { alfa.received("openTab").count == 1 })
        let request = alfa.received("openTab")[0]["requestId"] ?? .null
        beta.send(["type": "result", "requestId": request, "ok": true, "tabId": 99])
        try await Task.sleep(for: .milliseconds(200))
        alfa.send(["type": "result", "requestId": request, "ok": true, "tabId": 7])
        let page = try await opening.value
        #expect(page.targetID == "tab-7", "the answer that counted is A's own, not B's tab 99")

        // A comes back on a new link while a command waits on the old one: the old transport ends, the command fails
        // unanswered (its effect uncertain), and nothing from the old link can complete it.
        let waiting = Task { try await page.send("Runtime.evaluate", ["expression": "1"]) }
        #expect(await Self.eventually { alfa.received("cdp").count == 1 })
        let replacement = try FakeInstance(socket: hub.socketPath, respond: silent)
        replacement.hello("A", paired: "Personale")
        await #expect(throws: CDPError.self) { try await waiting.value }
        #expect(replacement.received("cdp").isEmpty, "nothing was replayed on the new link")
        hub.stop()
    }

    // MARK: Closing and revocation

    @Test("closing closes Braus's tab and the popup its page opened, and nothing else")
    func closesOnlyItsOwn() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = ChromeProfileHub(directory: directory)
        try hub.start()
        let alfa = try FakeInstance(socket: hub.socketPath)
        alfa.hello("A", paired: "Personale")
        _ = await Self.eventually { hub.profiles.count == 1 }
        let browser = try await hub.connect("A")
        _ = try await browser.openPage()
        alfa.send(["type": "popup", "tabId": 9, "openerTabId": 7])
        alfa.send(["type": "popup", "tabId": 12, "openerTabId": 3])
        try await Task.sleep(for: .milliseconds(200))
        await browser.close()
        #expect(await Self.eventually { Set(alfa.received("closeTab").compactMap { $0["tabId"]?.intValue }) == [7, 9] })
        try await Task.sleep(for: .milliseconds(200))
        #expect(Set(alfa.received("closeTab").compactMap { $0["tabId"]?.intValue }) == [7, 9],
                "tab 12, opened by a page that is not Braus's, is never closed")
        #expect(!alfa.received.contains { $0["method"]?.stringValue == "Browser.close" })
        hub.stop()
    }

    @Test("once a revocation is processed nothing more is dispatched; a command already sent ends uncertain")
    func revocationStopsDispatch() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = ChromeProfileHub(directory: directory)
        try hub.start()
        let opener: @Sendable (FakeInstance, JSONValue) -> Void = { instance, message in
            if message["type"]?.stringValue == "openTab" { FakeInstance.chrome(instance, message) }
        }
        let alfa = try FakeInstance(socket: hub.socketPath, respond: opener)
        alfa.hello("A", paired: "Personale")
        _ = await Self.eventually { hub.profiles.count == 1 }
        let browser = try await hub.connect("A")
        let page = try await browser.openPage()

        let inFlight = Task { try await page.send("Runtime.evaluate", ["expression": "1"]) }
        #expect(await Self.eventually { alfa.received("cdp").count == 1 }, "the first command went out")
        alfa.send(["type": "revoked"])
        #expect(await Self.eventually { hub.profiles.isEmpty })
        await #expect(throws: CDPError.self) { try await inFlight.value }
        await #expect(throws: CDPError.self) { try await page.send("Runtime.evaluate", ["expression": "2"]) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(alfa.received("cdp").count == 1, "nothing was dispatched after the revocation")
        #expect(!(await browser.isRunning()))
        hub.stop()
    }

    @Test("the transport's barrier: once ended, a command reaching it directly is refused and nothing goes out")
    func barrierAfterEnd() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = ChromeProfileHub(directory: directory)
        try hub.start()
        let alfa = try FakeInstance(socket: hub.socketPath)
        alfa.hello("A", paired: "Personale")
        _ = await Self.eventually { hub.profiles.count == 1 }
        let transport = try hub.transport(for: "A")
        var frames = transport.incoming.makeAsyncIterator()
        try transport.send(JSONEncoder().encode(JSONValue.object([
            "id": 1, "method": "Target.createTarget", "params": ["url": "about:blank"]])))
        let opened = try #require(await frames.next())
        #expect(String(decoding: opened, as: UTF8.self).contains("tab-7"))
        let command = try JSONEncoder().encode(JSONValue.object([
            "id": 2, "method": "Runtime.evaluate", "params": ["expression": "1"], "sessionId": "tab-7"]))
        try transport.send(command)
        #expect(await Self.eventually { alfa.received("cdp").count == 1 }, "before the end, the command goes out")
        // The end a revocation or a disconnect makes, then a command that was already on its way to the transport.
        transport.end()
        #expect(throws: ChromeProfileError.self) { try transport.send(command) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(alfa.received("cdp").count == 1, "nothing went out after the end")
        hub.stop()
    }

    @Test("a closed gate: a new command or tab is refused with nothing sent, and closing Braus's tab still goes out")
    func gateClosedOnChoiceChange() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = ChromeProfileHub(directory: directory)
        try hub.start()
        let alfa = try FakeInstance(socket: hub.socketPath)
        alfa.hello("A", paired: "Personale")
        _ = await Self.eventually { hub.profiles.count == 1 }
        let gate = CommandGate()
        let transport = try hub.transport(for: "A", gate: gate)
        let answers = Answers()
        let reading = Task {
            for await frame in transport.incoming {
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: frame.dropLast()),
                      let id = message["id"]?.intValue else { continue }
                answers.values.withLock { $0[id] = message }
            }
        }
        defer { reading.cancel() }
        func command(_ id: Int, _ method: String, _ params: JSONValue = [:], tab: Bool = false) throws {
            var object: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method), "params": params]
            if tab { object["sessionId"] = "tab-7" }
            try transport.send(JSONEncoder().encode(JSONValue.object(object)))
        }
        /// The answer to command `id`.
        func answer(_ id: Int) async -> JSONValue? {
            _ = await Self.eventually { answers.values.withLock { $0[id] != nil } }
            return answers.values.withLock { $0[id] }
        }
        try command(1, "Target.createTarget", ["url": "about:blank"])
        #expect(await answer(1)?["result"]?["targetId"]?.stringValue == "tab-7")
        try command(2, "Runtime.evaluate", ["expression": "1"], tab: true)
        #expect(await answer(2)?["result"] != nil, "before the change, the command goes out")
        // The conversation's choice changed: a call under way sends its next commands.
        gate.close()
        try command(3, "Input.dispatchMouseEvent", ["type": "mousePressed"], tab: true)
        #expect(await answer(3)?["error"]?["message"]?.stringValue?.contains("no longer 'Personale'") == true)
        try command(4, "Target.createTarget", ["url": "about:blank"])
        #expect(await answer(4)?["error"] != nil)
        try command(5, "Target.closeTarget", ["targetId": "tab-7"])
        #expect(await answer(5)?["result"]?["success"]?.boolValue == true, "Braus's own tab still closes")
        #expect(alfa.received("cdp").count == 1 && alfa.received("openTab").count == 1, "nothing new went out")
        #expect(alfa.received("closeTab").count == 1)
        hub.stop()
    }

    @Test("an instance that disconnects mid-command leaves the command unanswered, never answered for it")
    func disconnectMidCommand() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = ChromeProfileHub(directory: directory)
        try hub.start()
        let opener: @Sendable (FakeInstance, JSONValue) -> Void = { instance, message in
            if message["type"]?.stringValue == "openTab" { FakeInstance.chrome(instance, message) }
        }
        let alfa = try FakeInstance(socket: hub.socketPath, respond: opener)
        alfa.hello("A", paired: "Personale")
        _ = await Self.eventually { hub.profiles.count == 1 }
        let page = try await hub.connect("A").openPage()
        let inFlight = Task { try await page.send("Input.dispatchMouseEvent", ["type": "mousePressed"]) }
        #expect(await Self.eventually { alfa.received("cdp").count == 1 })
        alfa.disconnect()
        await #expect(throws: CDPError.connectionClosed(method: "Input.dispatchMouseEvent")) {
            try await inFlight.value
        }
        #expect(await Self.eventually { hub.profiles.first?.isConnected == false })
        hub.stop()
    }

    // MARK: Lifetime

    @Test("a revoked pairing does not come back when an older write of the pairings lands last")
    func pairingsWrittenInOrder() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hub = ChromeProfileHub(directory: directory)
        // Change 1 paired "Lavoro" beside "Personale"; change 2 revoked it. Their writes cross: 2 lands first.
        hub.persist(["A": "Personale"], generation: 2)
        hub.persist(["A": "Personale", "B": "Lavoro"], generation: 1)
        #expect(ChromeProfileHub(directory: directory).profiles.map(\.label) == ["Personale"], "after a relaunch")
    }

    @Test("a link's socket fails a write to a host gone instead of raising SIGPIPE")
    func noSIGPIPE() async throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let ended = Mutex(false)
        let link = ExtensionLink(descriptor: pair[0], receive: { _, _ in },
                                 ended: { _ in ended.withLock { $0 = true } })
        var option: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &option, &size) == 0 && option != 0)
        Darwin.close(pair[1])
        #expect(throws: ChromeProfileError.notRunning) {
            for _ in 0..<64 { try link.send(.object(["type": .string("cdp"), "id": .number(1)])) }
        }
        #expect(await Self.eventually { ended.withLock { $0 } })
    }
}
