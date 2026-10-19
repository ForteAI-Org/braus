import AppAdapters
import EngineCore
import Foundation
import LocalMCP
import Testing

/// FakeMailTransport is Mail in memory: an inbox, a sent mailbox and drafts. `dropsSends` plays a
/// Mail that takes a message and never files it; `permissionNeeded` one the check before any script
/// refuses, so nothing is handed over; `failReads`
/// one whose sent and drafts mailboxes fail once a message or a draft went out, and `failSends` one
/// whose send fails midway, after the message was handed over. `ignoreSender` sends from the default
/// account whatever was asked; `alterBody` files another text; `seed` puts an equal message or draft
/// there before the call; `draftAlongside` saves another draft of the same subject with the next one.
actor FakeMailTransport: MailTransporting {
    var inbox: [MailMessage] = [
        MailMessage(id: "<old@x>", subject: "Invoice", sender: "Shop <shop@example.com>",
                    date: Date(timeIntervalSince1970: 1_000), isRead: true, content: "Paid."),
        MailMessage(id: "<new@x>", subject: "Braus test", sender: "Anna <anna@example.com>",
                    date: Date(timeIntervalSince1970: 2_000), isRead: false, content: "Hello"),
    ]
    var sentBox: [MailMessage] = []
    var draftBox: [MailMessage] = []
    var dropsSends = false
    var permissionNeeded = false
    private(set) var sends = 0
    private var ignoresSender = false
    private var altersBody = false
    private var draftsAlongside = false
    private var hidesText = false

    func ignoreSender() { ignoresSender = true }
    /// Mail gives no text for a new message or draft.
    func hideText() { hidesText = true }
    func alterBody() { altersBody = true }
    func draftAlongside() { draftsAlongside = true }
    func seed(sent mail: MailMessage) { sentBox.append(mail) }
    func seed(draft: MailMessage) { draftBox.append(draft) }

    /// What `availability` answers: the Mac's grant as the transport reads it without prompting.
    var grant = AdapterAvailability.ready
    private var wrote = false
    private var readFailure: (any Error & Sendable)?
    private var sendFailure: (any Error & Sendable)?

    func failReads(afterWrite error: any Error & Sendable) { readFailure = error }

    func failSends(with error: any Error & Sendable) { sendFailure = error }

    init(dropsSends: Bool = false, permissionNeeded: Bool = false) {
        self.dropsSends       = dropsSends
        self.permissionNeeded = permissionNeeded
    }

    func availability() async -> AdapterAvailability { grant }

    func answer(_ grant: AdapterAvailability) { self.grant = grant }

    func messages(matching query: String?, unreadOnly: Bool, limit: Int) async throws -> [MailMessage] {
        if permissionNeeded { throw AutomationPermissionNeeded("Allow Mail in Automation.", beforeAnyEvent: true) }
        return inbox.filter { message in
            (!unreadOnly || !message.isRead)
                && (query.map { message.subject.contains($0) || message.sender.contains($0) } ?? true)
        }
    }

    func message(id: String) async throws -> MailMessage? {
        guard let found = (inbox + sentBox).first(where: { $0.id == id }) else { return nil }
        return hidesText ? MailMessage(id: found.id, subject: found.subject, sender: found.sender, date: found.date,
                                       recipients: found.recipients) : found
    }

    func send(to address: String, subject: String, body: String, from sender: String?) async throws {
        if permissionNeeded { throw AutomationPermissionNeeded("Allow Mail in Automation.", beforeAnyEvent: true) }
        sends += 1
        wrote = true
        if let sendFailure { throw sendFailure }
        guard !dropsSends else { return }
        let from = ignoresSender ? "Me <me@example.com>" : sender.map { "Me <\($0)>" } ?? "Me <me@example.com>"
        sentBox.append(MailMessage(id: "<sent-\(sends)@x>", subject: subject, sender: from, date: Date(),
                                   recipients: [address], content: altersBody ? "Another text" : body + "\n\n--\nMe"))
    }

    func saveDraft(to address: String?, subject: String, body: String, from sender: String?) async throws {
        wrote = true
        let from = ignoresSender ? "Me <me@example.com>" : sender.map { "Me <\($0)>" } ?? "Me <me@example.com>"
        let text = hidesText ? nil : altersBody ? "Another text" : body
        draftBox.append(MailMessage(id: "<draft-\(draftBox.count)@x>", subject: subject, sender: from,
                                    date: Date(), recipients: address.map { [$0] } ?? [], content: text))
        if draftsAlongside {
            draftBox.append(MailMessage(id: "<draft-\(draftBox.count)@x>", subject: subject, sender: from,
                                        date: Date(), recipients: address.map { [$0] } ?? [], content: text))
        }
    }

    func drafts(subject: String) async throws -> [MailMessage] {
        if wrote, let readFailure { throw readFailure }
        return draftBox.filter { $0.subject == subject }
    }

    func sent(subject: String, since: Date) async throws -> [MailMessage] {
        if wrote, let readFailure { throw readFailure }
        return sentBox.filter { $0.subject == subject && ($0.date ?? .distantPast) >= since }
    }
}

/// The Mail adapter on a fake Mail: the inbox searched newest first, a send read back in the sent
/// mailbox, a name refused where an address belongs, the send behind the destructive policy.
@Suite("Mail adapter")
struct MailAdapterTests {

    static func adapter(_ transport: FakeMailTransport) -> MailAdapter {
        MailAdapter(transport: transport, readBackTries: 2, readBackPause: .milliseconds(1))
    }

    @Test("find_messages answers newest first and filters unread and words")
    func find() async throws {
        let adapter = Self.adapter(FakeMailTransport())
        let all = try await adapter.call("find_messages", .object([:]))
        #expect(all.result["messages"].array?.map { $0["id"] } == [.string("<new@x>"), .string("<old@x>")])
        let unread = try await adapter.call("find_messages", .object(["unread_only": .bool(true)]))
        #expect(unread.result["messages"].array?.count == 1)
        let shop = try await adapter.call("find_messages", .object(["query": .string("shop")]))
        #expect(shop.result["messages"].array?.first?["subject"] == .string("Invoice"))
    }

    @Test("read_message answers the text; an unknown id is a miss")
    func read() async throws {
        let adapter = Self.adapter(FakeMailTransport())
        let message = try await adapter.call("read_message", .object(["id": .string("<new@x>")]))
        #expect(message.result["text"] == .string("Hello"))
        #expect(try await adapter.call("read_message", .object(["id": .string("<none@x>")])).kind == .honestMiss)
    }

    @Test("send is confirmed by the sent mailbox, by subject and recipient")
    func send() async throws {
        let transport = FakeMailTransport()
        let outcome = try await Self.adapter(transport).call("send", .object([
            "to": .string("me@example.com"), "subject": .string("Braus test"), "body": .string("Hi"),
        ]))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.result["to"] == .array([.string("me@example.com")]))
    }

    @Test("A send the sent mailbox never shows is unverified, and sent once")
    func sendUnverified() async throws {
        let transport = FakeMailTransport(dropsSends: true)
        let outcome = try await Self.adapter(transport).call("send", .object([
            "to": .string("me@example.com"), "subject": .string("Braus test"), "body": .string("Hi"),
        ]))
        #expect(outcome.kind == .actedUnverified)
        #expect(await transport.sends == 1)
    }

    @Test("A name where the address belongs is refused before anything is sent")
    func nameRefused() async throws {
        let transport = FakeMailTransport()
        let outcome = try await Self.adapter(transport).call("send", .object([
            "to": .string("Anna Rossi"), "subject": .string("Braus test"), "body": .string("Hi"),
        ]))
        #expect(outcome.kind == .refused)
        #expect(await transport.sends == 0)
    }

    @Test("create_draft is read back in the drafts mailbox")
    func draft() async throws {
        let outcome = try await Self.adapter(FakeMailTransport()).call("create_draft", .object([
            "subject": .string("Braus test"), "body": .string("Draft"),
        ]))
        #expect(outcome.kind == .foundActed)
    }

    @Test("send cannot run while destructive actions are off")
    func sendGuarded() async throws {
        let transport = FakeMailTransport()
        let outcome = try await AppAdapters([Self.adapter(transport)]).call(app: "Mail", verb: "mail.send", arguments: .object([
            "to": .string("me@example.com"), "subject": .string("Braus test"), "body": .string("Hi"),
        ]))
        #expect(outcome.kind == .refused)
        #expect(await transport.sends == 0)
    }

    static let mail: JSONValue = .object(["to": .string("me@example.com"), "subject": .string("Braus test"),
                                          "body": .string("Hi")])

    @Test("A02/A08: the permission withdrawn, or the sent mailbox failing, after the message went out: unverified, it may have happened, sent once and never refused",
          arguments: [true, false])
    func readBackFailsAfterSend(permission: Bool) async throws {
        let transport = FakeMailTransport()
        await transport.failReads(afterWrite: permission ? AutomationPermissionNeeded("Allow Mail in Automation.")
                                                         : AdapterFailure("the sent mailbox did not answer"))
        let outcome = try await Self.adapter(transport).call("send", Self.mail)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("may have happened"),
                Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A02: a Mail the check before any script refuses: the send is refused, and nothing was handed over")
    func refusedBeforeSend() async throws {
        let transport = FakeMailTransport(permissionNeeded: true)
        let outcome = try await Self.adapter(transport).call("send", Self.mail)
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(await transport.sends == 0)
    }

    @Test("A02: the permission refused while the send's script ran, after the message was handed over: unverified, it may have happened, never refused")
    func permissionWhileSending() async throws {
        let transport = FakeMailTransport()
        await transport.failSends(with: AutomationPermissionNeeded("Allow Mail in Automation."))
        let outcome = try await Self.adapter(transport).call("send", Self.mail)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("may have happened"),
                Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A08: a send that fails after the message was handed over is answered unverified, never thrown, and not tried again")
    func sendFailsMidway() async throws {
        let transport = FakeMailTransport()
        await transport.failSends(with: AdapterFailure("Mail did not answer in time"))
        let outcome = try await Self.adapter(transport).call("send", Self.mail)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("may have happened"),
                Comment(rawValue: outcome.message))
        #expect(!outcome.message.contains("did not answer in time"), "the error's own text stays out")
        #expect(await transport.sends == 1)
    }

    @Test("A08: a call cancelled while it reads the send back keeps the receipt: unverified, it may have happened")
    func cancelledReadBack() async throws {
        let transport = FakeMailTransport(dropsSends: true)
        let adapter = MailAdapter(transport: transport, readBackTries: 50, readBackPause: .milliseconds(100))
        let call = Task { try await adapter.call("send", Self.mail) }
        try await Task.sleep(for: .milliseconds(150))
        call.cancel()
        let outcome = try await call.value
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("cancelled"), Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A02/A08: the drafts mailbox failing after the draft was saved: unverified, it may have happened")
    func draftReadBackFails() async throws {
        let transport = FakeMailTransport()
        await transport.failReads(afterWrite: AutomationPermissionNeeded("Allow Mail in Automation."))
        let outcome = try await Self.adapter(transport).call("create_draft", .object([
            "subject": .string("Braus test"), "body": .string("Draft"),
        ]))
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("may have happened"),
                Comment(rawValue: outcome.message))
    }

    @Test("A01: discovery reports a grant the Mac cannot answer as unknown, never ready; a verb still runs and checks it itself; a refused grant refuses")
    func unknownGrant() async throws {
        let transport = FakeMailTransport()
        await transport.answer(.unknown("Mail is not running."))
        let adapters = AppAdapters([Self.adapter(transport)])
        let capabilities = await adapters.capabilities(of: "Mail", query: nil).json
        #expect(capabilities["availability"]["state"] == .string("unknown"), "\(capabilities)")
        let read = try await adapters.call(app: "Mail", verb: "find_messages", arguments: .object([:]))
        #expect(read.kind == .foundActed, Comment(rawValue: read.message))
        await transport.answer(.needsPermission("Allow Mail in Automation."))
        let refused = try await adapters.call(app: "Mail", verb: "find_messages", arguments: .object([:]))
        #expect(refused.kind == .refused)
    }

    @Test("A03: sent from the account named, the one new message of that subject to that address, with its text: confirmed")
    func sentFromTheAccountAsked() async throws {
        let outcome = try await Self.adapter(FakeMailTransport()).call("send", .object([
            "to": .string("anna@example.com"), "subject": .string("Braus test"), "body": .string("Hi"),
            "from": .string("work@example.com"),
        ]))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.result["sender"] == .string("Me <work@example.com>"), "\(outcome.result)")
    }

    @Test("A03: a message Mail sent from another account than the one named is unverified, and says from which")
    func sentFromAnotherAccount() async throws {
        let transport = FakeMailTransport()
        await transport.ignoreSender()
        let outcome = try await Self.adapter(transport).call("send", .object([
            "to": .string("anna@example.com"), "subject": .string("Braus test"), "body": .string("Hi"),
            "from": .string("work@example.com"),
        ]))
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("not the account asked for"),
                Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A03/A04: an equal message already in the sent mailbox, sent a moment before, is never taken for this send")
    func earlierEqualMessage() async throws {
        let transport = FakeMailTransport(dropsSends: true)
        await transport.seed(sent: MailMessage(id: "<earlier@x>", subject: "Braus test", sender: "Me <me@example.com>",
                                               date: Date(), recipients: ["me@example.com"], content: "Hi"))
        let outcome = try await Self.adapter(transport).call("send", Self.mail)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
    }

    @Test("A03: the new message's text is not the one asked for: unverified")
    func anotherText() async throws {
        let transport = FakeMailTransport()
        await transport.alterBody()
        let outcome = try await Self.adapter(transport).call("send", Self.mail)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("text"), Comment(rawValue: outcome.message))
    }

    @Test("A03: a new message whose text Mail does not give is unverified, never confirmed on the rest")
    func sentTextNotGiven() async throws {
        let transport = FakeMailTransport()
        await transport.hideText()
        let outcome = try await Self.adapter(transport).call("send", Self.mail)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("could not be read back"),
                Comment(rawValue: outcome.message))
    }

    @Test("A04: a new draft with another text, or whose text Mail does not give, is unverified", arguments: [true, false])
    func draftText(hidden: Bool) async throws {
        let transport = FakeMailTransport()
        if hidden { await transport.hideText() } else { await transport.alterBody() }
        let outcome = try await Self.adapter(transport).call("create_draft", .object([
            "subject": .string("Braus test"), "body": .string("Draft"),
        ]))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains(hidden ? "could not be read back" : "not the one asked for"),
                Comment(rawValue: outcome.message))
    }

    @Test("A04: an equal draft already in the drafts mailbox is never taken for this one; two new drafts of that subject are unverified")
    func draftIdentity() async throws {
        let earlier = FakeMailTransport()
        await earlier.seed(draft: MailMessage(id: "<old-draft@x>", subject: "Braus test", sender: "Me <me@example.com>",
                                              date: Date(), recipients: ["anna@example.com"]))
        let draft: JSONValue = .object(["to": .string("anna@example.com"), "subject": .string("Braus test"),
                                        "body": .string("Draft")])
        let saved = try await Self.adapter(earlier).call("create_draft", draft)
        #expect(saved.kind == .foundActed && saved.result["id"] != .string("<old-draft@x>"), Comment(rawValue: saved.message))

        let alongside = FakeMailTransport()
        await alongside.draftAlongside()
        let two = try await Self.adapter(alongside).call("create_draft", draft)
        #expect(two.kind == .actedUnverified && two.message.contains("2 new drafts"), Comment(rawValue: two.message))
    }

    @Test("A Mail that would prompt for Automation is a refusal with the reason")
    func permission() async throws {
        let outcome = try await Self.adapter(FakeMailTransport(permissionNeeded: true)).call("find_messages", .object([:]))
        #expect(outcome.kind == .refused)
        #expect(outcome.message.contains("Automation"))
    }

    @Test("Live: the inbox answers, and a mail to the developer's own address reads back",
          .enabled(if: Live.adapters))
    func live() async throws {
        let adapter = MailAdapter(transport: MacMailTransport())
        guard await adapter.availability().isReady else { return }
        let found = try await adapter.call("find_messages", .object(["limit": .number(3)]))
        #expect(found.kind == .foundActed || found.kind == .refused)
        guard found.kind == .foundActed, let own = Live.ownAddress else { return }
        let sent = try await adapter.call("send", .object([
            "to": .string(own), "subject": .string("Braus test \(UUID().uuidString.prefix(8))"),
            "body": .string("Braus test: Mail adapter live send."),
        ]))
        #expect(sent.kind == .foundActed)
    }
}
