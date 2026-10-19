import AppAdapters
import EngineCore
import Foundation
import LocalMCP
import Testing

/// An irreversible verb asks the person about each call, with what it would do in a readable summary: allowed, it runs
/// once; refused, unanswered or cancelled, nothing is sent; with nobody to ask, it is refused as before. Read and
/// write verbs never ask.
@Suite("App adapters: the person's consent to an irreversible call")
struct AdapterConsentTests {

    private static let mail: JSONValue = .object([
        "to"     : .string("anna@example.com"),
        "subject": .string("Braus test"),
        "body"   : .string("Line one\nLine two\nLine three\nLine four, not shown"),
    ])

    private static func adapters(_ transport: FakeMailTransport, _ approver: FakeApprover?) -> AppAdapters {
        AppAdapters([MailAdapterTests.adapter(transport)], approver: approver)
    }

    /// Waits, a few milliseconds at a time and for at most two seconds, until `condition` holds.
    private static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("allowed, a send runs once, after the person read its recipient, subject and first lines")
    func allowedRunsOnce() async throws {
        let transport = FakeMailTransport()
        let approver  = FakeApprover(.allow)
        let outcome   = try await Self.adapters(transport, approver).call(app: "Mail", verb: "send", arguments: Self.mail)
        #expect(outcome.kind == .foundActed && outcome.confirmedByReadBack, Comment(rawValue: outcome.message))
        #expect(await transport.sends == 1)
        let asked = await approver.asked
        #expect(asked.count == 1)
        #expect(asked.first?.adapter == "mail" && asked.first?.app == "Mail" && asked.first?.verb == "send")
        #expect(asked.first?.arguments["to"] == .string("anna@example.com"))
        #expect(asked.first?.arguments["subject"] == .string("Braus test"))
        #expect(asked.first?.arguments["body"] == .string("Line one\nLine two\nLine three…"))
    }

    @Test("refused, or with nobody to ask, a send is refused and nothing is sent", arguments: [true, false])
    func refusedSendsNothing(hasApprover: Bool) async throws {
        let transport = FakeMailTransport()
        let approver  = hasApprover ? FakeApprover(.refuse) : nil
        let outcome   = try await Self.adapters(transport, approver).call(app: "Mail", verb: "send", arguments: Self.mail)
        #expect(outcome.kind == .refused)
        #expect(outcome.message.contains(hasApprover ? "did not allow mail.send" : "destructive actions are off"),
                Comment(rawValue: outcome.message))
        #expect(await transport.sends == 0)
    }

    @Test("a consent left waiting holds back no other call, and cancelled, it refuses with nothing sent")
    func cancelledWhileWaiting() async throws {
        let transport = FakeMailTransport()
        let approver  = FakeApprover(.waitUntilCancelled)
        let adapters  = Self.adapters(transport, approver)
        let waiting   = Task { try await adapters.call(app: "Mail", verb: "send", arguments: Self.mail) }
        await Self.until { await !approver.asked.isEmpty }
        let read = try await adapters.call(app: "Mail", verb: "find_messages", arguments: .object([:]))
        #expect(read.kind == .foundActed)
        waiting.cancel()
        let outcome = try await waiting.value
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(await transport.sends == 0)
    }

    @Test("a deletion names the event by its title and date, and runs once")
    func deletionNamesTheEvent() async throws {
        let store = FakeEventStore()
        await store.add(StoreEvent(id: "e1", title: "Dentist", start: Date(timeIntervalSince1970: 1_800_000_000),
                                   end: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false, calendarID: "home"))
        let approver = FakeApprover(.allow)
        let outcome  = try await AppAdapters([CalendarAdapter(store: store)], approver: approver)
            .call(app: "calendar", verb: "delete_event", arguments: .object(["id": .string("e1")]))
        #expect(outcome.kind == .foundActed && outcome.confirmedByReadBack)
        #expect(await store.events.isEmpty)
        let asked = try #require(await approver.asked.first)
        #expect(asked.arguments["title"] == .string("Dentist"))
        #expect(asked.arguments["date"]?.string?.isEmpty == false)
        #expect(asked.arguments["id"] == nil)
    }

    @Test("read and write verbs never ask")
    func readAndWriteNeverAsk() async throws {
        let approver = FakeApprover(.refuse)
        let adapters = AppAdapters([CalendarAdapter(store: FakeEventStore())], approver: approver)
        let read     = try await adapters.call(app: "calendar", verb: "list_calendars", arguments: .null)
        let written  = try await adapters.call(app: "calendar", verb: "create_event", arguments: .object([
            "title": .string("Braus test"), "start": .string("2027-01-04T10:00:00Z"),
        ]))
        #expect(read.kind == .foundActed && written.kind == .foundActed, Comment(rawValue: written.message))
        #expect(await approver.asked.isEmpty)
    }

    @Test("a text the person reads is cut to its first lines and characters")
    func excerpt() {
        #expect(AdapterConsent.excerpt("one\ntwo") == "one\ntwo")
        #expect(AdapterConsent.excerpt("a\nb\nc\nd") == "a\nb\nc…")
        let long = String(repeating: "x", count: AdapterConsent.excerptLength + 5)
        #expect(AdapterConsent.excerpt(long) == String(repeating: "x", count: AdapterConsent.excerptLength) + "…")
    }
}
