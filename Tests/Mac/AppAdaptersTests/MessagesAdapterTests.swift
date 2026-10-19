import AppAdapters
import EngineCore
import Foundation
import LocalMCP
import Testing

/// FakeMessagesTransport is Messages with a history in memory. `history: false` plays a Mac where
/// Braus cannot read the history (no Full Disk Access); `drops` one that takes the message and never
/// records it; `seeded` messages already in the window, sent by someone else or a moment before;
/// `refusesBeforeSend` one the check before any script refuses; `sendFailure` a send that fails once
/// the message went out; `readFailure` a history that fails once a message went out.
actor FakeMessagesTransport: MessagesTransporting {
    let history: Bool
    let drops  : Bool
    let fails  : Bool
    private(set) var log: [SentMessage] = []
    private(set) var sends = 0
    private var refusesBeforeSend = false
    private var sendFailure: (any Error & Sendable)?
    private var readFailure: (any Error & Sendable)?
    private var richTextOnly = false
    private var readFailureBefore: (any Error & Sendable)?
    private var losesHistory = false

    func refuseBeforeSend() { refusesBeforeSend = true }

    /// The history keeps the texts it records in their rich form only: it gives none.
    func keepRichTextOnly() { richTextOnly = true }

    func failSends(with error: any Error & Sendable) { sendFailure = error }

    func failReads(afterSend error: any Error & Sendable) { readFailure = error }

    /// The history fails to read before any message went out.
    func failReads(beforeSend error: any Error & Sendable) { readFailureBefore = error }

    /// The history, readable before the send, cannot be read after it (Full Disk Access withdrawn).
    func loseHistoryAfterSend() { losesHistory = true }

    init(history: Bool = true, drops: Bool = false, fails: Bool = false, seeded: [SentMessage] = []) {
        self.history = history
        self.drops   = drops
        self.fails   = fails
        self.log     = seeded
    }

    func availability() async -> AdapterAvailability { .ready }

    func send(_ text: String, to handle: String) async throws {
        if refusesBeforeSend { throw AutomationPermissionNeeded("Allow Messages in Automation.", beforeAnyEvent: true) }
        sends += 1
        if let sendFailure { throw sendFailure }
        guard !drops else { return }
        // The history writes the handle in international form and the text as sent.
        let stored = handle.contains("@") ? handle : "+39" + handle.filter(\.isNumber).suffix(10)
        log.insert(SentMessage(id: "row-\(sends)", handle: stored, text: richTextOnly ? nil : text, date: Date(),
                               failed: fails), at: 0)
    }

    func sent(since: Date) async throws -> [SentMessage]? {
        if sends == 0, let readFailureBefore { throw readFailureBefore }
        if sends > 0, let readFailure { throw readFailure }
        if sends > 0, losesHistory { return nil }
        return history ? log.filter { $0.date >= since } : nil
    }
}

/// The Messages adapter on a fake Messages: the history confirms a send by handle and text, a Mac
/// without the history answers unverified, a name is refused, and the send waits for the policy.
@Suite("Messages adapter")
struct MessagesAdapterTests {

    static func adapter(_ transport: FakeMessagesTransport) -> MessagesAdapter {
        MessagesAdapter(transport: transport, readBackTries: 2, readBackPause: .milliseconds(1))
    }

    static let message: JSONValue = .object(["to": .string("+39 333 123 4567"), "text": .string("Braus test")])

    @Test("A send the history records is confirmed, the number matched by its whole identity")
    func confirmed() async throws {
        let outcome = try await Self.adapter(FakeMessagesTransport()).call("send_message", Self.message)
        #expect(outcome.kind == .foundActed)
        #expect(outcome.result["to"] == .string("+393331234567"))
    }

    @Test("R07: a history that cannot be read before the send, or fails to: refused, nothing sent, nothing asked",
          arguments: [false, true])
    func noHistory(failing: Bool) async throws {
        let transport = FakeMessagesTransport(history: failing)
        if failing { await transport.failReads(beforeSend: AdapterFailure("the history could not be read")) }
        let outcome = try await Self.adapter(transport).call("send_message", Self.message)
        #expect(outcome.kind == .refused && outcome.message.contains("nothing was sent"),
                Comment(rawValue: outcome.message))
        if !failing { #expect(outcome.message.contains("Full Disk Access")) }
        #expect(await transport.sends == 0)
    }

    @Test("R07: a history read before the send that cannot be read after it: unverified, sent once")
    func historyLostAfterSend() async throws {
        let transport = FakeMessagesTransport()
        await transport.loseHistoryAfterSend()
        let outcome = try await Self.adapter(transport).call("send_message", Self.message)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("could no longer be read"),
                Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A send the history never shows, or shows failed, is unverified and sent once")
    func unverified() async throws {
        let dropped = FakeMessagesTransport(drops: true)
        #expect(try await Self.adapter(dropped).call("send_message", Self.message).kind == .actedUnverified)
        #expect(await dropped.sends == 1)
        let failed = try await Self.adapter(FakeMessagesTransport(fails: true)).call("send_message", Self.message)
        #expect(failed.kind == .actedUnverified)
    }

    @Test("A02: a Messages the check before any script refuses: refused, and nothing was sent")
    func refusedBeforeSend() async throws {
        let transport = FakeMessagesTransport()
        await transport.refuseBeforeSend()
        let outcome = try await Self.adapter(transport).call("send_message", Self.message)
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(await transport.sends == 0)
    }

    @Test("A02/A08: a permission refused while the script ran, a send failing midway, or the history failing after the send: unverified, it may have happened, sent once",
          arguments: ["permission", "midway", "history"])
    func mayHaveHappened(failure: String) async throws {
        let transport = FakeMessagesTransport()
        switch failure {
            case "permission": await transport.failSends(with: AutomationPermissionNeeded("Allow Messages in Automation."))
            case "midway"    : await transport.failSends(with: AdapterFailure("Messages did not answer in time"))
            default          : await transport.failReads(afterSend: AdapterFailure("the history could not be read"))
        }
        let outcome = try await Self.adapter(transport).call("send_message", Self.message)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("may have happened"),
                Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A08: a call cancelled while it reads the history back keeps the receipt: unverified, it may have happened")
    func cancelledReadBack() async throws {
        let transport = FakeMessagesTransport(drops: true)
        let adapter = MessagesAdapter(transport: transport, readBackTries: 50, readBackPause: .milliseconds(100))
        let call = Task { try await adapter.call("send_message", Self.message) }
        try await Task.sleep(for: .milliseconds(150))
        call.cancel()
        let outcome = try await call.value
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("cancelled"), Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A06: an equal message already in the history, sent a moment before, is never taken for this send, which the history does not show")
    func earlierEqualRow() async throws {
        let earlier = SentMessage(id: "row-earlier", handle: "+393331234567", text: "Braus test", date: Date())
        let transport = FakeMessagesTransport(drops: true, seeded: [earlier])
        let outcome = try await Self.adapter(transport).call("send_message", Self.message)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.result["delivery"] == .string("unknown"))
        #expect(await transport.sends == 1)
    }

    @Test("A06: a delivery recorded as failed keeps its state, sent once; a history lost after the send says unknown",
          arguments: [true, false])
    func deliveryState(history: Bool) async throws {
        let transport = FakeMessagesTransport(fails: true)
        if !history { await transport.loseHistoryAfterSend() }
        let outcome = try await Self.adapter(transport).call("send_message", Self.message)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.result["delivery"] == .string(history ? "failed" : "unknown"), "\(outcome.result)")
        #expect(await transport.sends == 1)
    }

    @Test("A name is refused before anything is sent")
    func name() async throws {
        let transport = FakeMessagesTransport()
        let outcome = try await Self.adapter(transport).call("send_message", .object([
            "to": .string("Anna"), "text": .string("Braus test"),
        ]))
        #expect(outcome.kind == .refused)
        #expect(await transport.sends == 0)
    }

    @Test("A05: a handle matches by its whole identity: an email in lower case, a number by all its digits, 00 as +; a number without its prefix never matches one with it")
    func handles() {
        #expect(MessagesAdapter.matches("+393331234567", asked: "+39 333 123 4567"))
        #expect(MessagesAdapter.matches("+393331234567", asked: "0039 333 123 4567"))
        #expect(!MessagesAdapter.matches("+13331234567", asked: "+39 333 123 4567"), "another country, the same ending")
        #expect(!MessagesAdapter.matches("+393331234567", asked: "333 123 4567"), "which country would be a guess")
        #expect(!MessagesAdapter.matches("+447700900123", asked: "07700 900123"), "no regional rule is invented")
        #expect(MessagesAdapter.matches("3331234567", asked: "333 123 4567"), "both without a prefix, the same digits")
        #expect(MessagesAdapter.matches("anna@example.com", asked: "Anna@Example.com"))
        #expect(!MessagesAdapter.matches("+393331234567", asked: "12345"))
        #expect(MessagesAdapter.normalized("Anna") == nil && MessagesAdapter.normalized("12345") == nil)
    }

    @Test("A05: the only message in the window went to another number with the same ending: no confirmation")
    func onlyAWrongNumber() async throws {
        let wrong = SentMessage(id: "row-earlier", handle: "+13331234567", text: "Braus test", date: Date())
        let transport = FakeMessagesTransport(drops: true, seeded: [wrong])
        let outcome = try await Self.adapter(transport).call("send_message", Self.message)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A05: two messages with one ending, to the number asked for and to another: the one asked for confirms, never the other")
    func twoNumbersOneEnding() async throws {
        let other = SentMessage(id: "row-earlier", handle: "+13331234567", text: "Braus test", date: Date())
        let transport = FakeMessagesTransport(seeded: [other])
        let outcome = try await Self.adapter(transport).call("send_message", Self.message)
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.result["to"] == .string("+393331234567"))
    }

    @Test("A05: a number given without its prefix, where the history writes it with one, is not confirmed, and says why")
    func numberWithoutPrefix() async throws {
        let transport = FakeMessagesTransport()
        let outcome = try await Self.adapter(transport).call("send_message", .object([
            "to": .string("333 123 4567"), "text": .string("Braus test"),
        ]))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("country prefix"), Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A05: a message to that number whose text the history does not give is no confirmation")
    func unknownText() async throws {
        let transport = FakeMessagesTransport()
        await transport.keepRichTextOnly()
        let outcome = try await Self.adapter(transport).call("send_message", Self.message)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("not its text"), Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("send_message cannot run while destructive actions are off")
    func guarded() async throws {
        let transport = FakeMessagesTransport()
        let outcome = try await AppAdapters([Self.adapter(transport)]).call(app: "Messaggi", verb: "send_message",
                                                                            arguments: Self.message)
        #expect(outcome.kind == .refused)
        #expect(await transport.sends == 0)
    }

    @Test("Live: a message to the developer's own handle", .enabled(if: Live.adapters && Live.ownAddress != nil))
    func live() async throws {
        let adapter = MessagesAdapter(transport: MacMessagesTransport())
        guard await adapter.availability().isReady, let own = Live.ownAddress else { return }
        let outcome = try await adapter.call("send_message", .object([
            "to": .string(own), "text": .string("Braus test: Messages adapter live send."),
        ]))
        #expect(outcome.kind == .foundActed || outcome.kind == .actedUnverified)
    }
}
