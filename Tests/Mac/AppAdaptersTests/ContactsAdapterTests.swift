import AppAdapters
import EngineCore
import Foundation
import LocalMCP
import Testing

/// FakeContactsStore is an address book in memory, matching names the way Contacts does: any part,
/// without case.
struct FakeContactsStore: ContactsStoring {
    var granted = ContactsAccess.granted
    /// What the person answers when asked.
    var answer: ContactsAccess?
    var people: [StoreContact] = [
        StoreContact(id: "anna", name: "Anna Rossi", organization: "Forte",
                     phones: [.init("mobile", "+39 333 123 4567")], emails: [.init("work", "anna@example.com")],
                     addresses: [.init("home", "Via Roma 1, Milano")], birthday: "--03-14"),
        StoreContact(id: "marco", name: "Marco Rossi", emails: [.init(nil, "marco@example.com")]),
    ]

    func access() -> ContactsAccess { granted }

    func requestAccess() async -> ContactsAccess { answer ?? granted }

    func contacts(matching name: String) async throws -> [StoreContact] {
        people.filter { $0.name.lowercased().contains(name.lowercased()) }
    }

    func contact(id: String) async throws -> StoreContact? { people.first { $0.id == id } }
}

/// The Contacts adapter on an in-memory address book: names to phones and addresses, a miss for
/// nobody, the permission asked about never prompted.
@Suite("Contacts adapter")
struct ContactsAdapterTests {

    @Test("find_contacts answers phones and emails, and caps the list")
    func find() async throws {
        let adapter = ContactsAdapter(store: FakeContactsStore())
        let outcome = try await adapter.call("find_contacts", .object(["name": .string("rossi")]))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.result["total"] == .number(2))
        let anna = try #require(outcome.result["contacts"].array?.first)
        #expect(anna["phones"].array?.first?["value"] == .string("+39 333 123 4567"))
        #expect(anna["emails"].array?.first?["value"] == .string("anna@example.com"))
        #expect(anna["addresses"] == .null)
        let one = try await adapter.call("find_contacts", .object(["name": .string("rossi"), "limit": .number(1)]))
        #expect(one.result["contacts"].array?.count == 1)
    }

    @Test("Nobody by that name is an honest miss")
    func nobody() async throws {
        let outcome = try await ContactsAdapter(store: FakeContactsStore()).call("find_contacts",
                                                                                 .object(["name": .string("Zoe")]))
        #expect(outcome.kind == .honestMiss)
    }

    @Test("read_contact adds the postal addresses and the birthday; an unknown id is a miss")
    func read() async throws {
        let adapter = ContactsAdapter(store: FakeContactsStore())
        let anna = try await adapter.call("read_contact", .object(["id": .string("anna")]))
        #expect(anna.result["birthday"] == .string("--03-14"))
        #expect(anna.result["addresses"].array?.count == 1)
        #expect(try await adapter.call("read_contact", .object(["id": .string("nobody")])).kind == .honestMiss)
    }

    @Test("Without access the adapter needs permission and the guarded call is refused")
    func permission() async throws {
        let adapter = ContactsAdapter(store: FakeContactsStore(granted: .notDetermined))
        guard case .needsPermission(let reason) = await adapter.availability() else {
            Issue.record("expected needsPermission")
            return
        }
        #expect(reason.contains("Privacy & Security > Contacts"))
        let outcome = try await AppAdapters([adapter]).call(app: "Contatti", verb: "find_contacts",
                                                            arguments: .object(["name": .string("Anna")]))
        #expect(outcome.kind == .refused)
    }

    @Test("Asking for the permission answers the availability after the person's answer; only the named adapter is asked")
    func request() async throws {
        let adapters = AppAdapters([ContactsAdapter(store: FakeContactsStore(granted: .notDetermined, answer: .granted)),
                                    SystemAdapter(transport: FakeSystemTransport())])
        let asked = await adapters.requestPermissions(for: "Contatti")
        #expect(asked.map(\.adapter.name) == ["contacts"])
        #expect(asked.first?.availability == .ready)
        #expect(await adapters.requestPermissions().count == 2)
    }

    @Test("Live: the Mac's address book answers a search", .enabled(if: Live.adapters))
    func live() async throws {
        let adapter = ContactsAdapter(store: MacContactsStore())
        guard await adapter.availability().isReady else { return }
        let outcome = try await adapter.call("find_contacts", .object(["name": .string("Braus test")]))
        #expect(outcome.kind == .foundActed || outcome.kind == .honestMiss)
    }
}

/// Live is whether the live adapter tests run: `BRAUS_ADAPTER_LIVE_TESTS=1`. They reach the Mac's
/// real apps with throwaway data named `Braus test`.
enum Live {
    static let adapters = ProcessInfo.processInfo.environment["BRAUS_ADAPTER_LIVE_TESTS"] == "1"
    /// The developer's own address, the only one a live send may reach: `BRAUS_ADAPTER_LIVE_SELF`.
    static let ownAddress = ProcessInfo.processInfo.environment["BRAUS_ADAPTER_LIVE_SELF"]
}
