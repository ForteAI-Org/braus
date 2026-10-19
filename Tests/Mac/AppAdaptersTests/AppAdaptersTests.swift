import AppAdapters
import EngineCore
import Foundation
import LocalMCP
import Testing

/// The one guarded path to the adapters: finding the adapter, checking arguments against the schema,
/// the destructive policy and the availability, before any adapter runs.
@Suite("App adapters: lookup, argument checks, destructive policy, availability")
struct AppAdaptersTests {

    static func adapters(store: FakeEventStore = FakeEventStore(), allowsIrreversible: Bool = false,
                         system: FakeSystemTransport = FakeSystemTransport()) -> AppAdapters {
        AppAdapters([SystemAdapter(transport: system), CalendarAdapter(store: store), RemindersAdapter(store: store)],
                    allowsIrreversible: allowsIrreversible)
    }

    @Test("An app is found by adapter name, app name or bundle id, without case")
    func lookup() {
        let adapters = Self.adapters()
        #expect(adapters.adapter(for: "calendar")?.name == "calendar")
        #expect(adapters.adapter(for: "Calendario")?.name == "calendar")
        #expect(adapters.adapter(for: "COM.APPLE.ICAL")?.name == "calendar")
        #expect(adapters.adapter(for: "System Settings")?.name == "system")
        #expect(adapters.adapter(for: "Pages") == nil)
    }

    @Test("A verb is accepted bare or qualified by its adapter")
    func qualifiedVerb() throws {
        let adapters = Self.adapters()
        #expect(try adapters.resolve(app: "system", verb: "system.get_volume", arguments: .null).verb.name == "get_volume")
        #expect(try adapters.resolve(app: "system", verb: "get_volume", arguments: .object([:])).verb.name == "get_volume")
        #expect(throws: AdapterFailure.self) { try adapters.resolve(app: "system", verb: "calendar.get_volume", arguments: .null) }
    }

    @Test("Arguments outside the schema are refused before the adapter runs", arguments: [
        ("set_volume", JSONValue.object(["level": .number(101)]), "level must be between 0 and 100."),
        ("set_volume", .object(["level": .number(4.5)]), "level must be a whole number."),
        ("set_volume", .object(["loud": .bool(true)]), "set_volume takes no argument loud."),
        ("set_appearance", .object([:]), "set_appearance needs appearance."),
        ("set_appearance", .object(["appearance": .string("sepia")]), "appearance must be one of light, dark."),
        ("set_wifi", .object(["on": .string("yes")]), "on must be a boolean."),
        ("get_wifi", .array([]), "arguments must be an object."),
    ])
    func schema(verb: String, arguments: JSONValue, message: String) async throws {
        let system = FakeSystemTransport()
        let error = await #expect(throws: AdapterFailure.self) {
            try await Self.adapters(system: system).call(app: "system", verb: verb, arguments: arguments)
        }
        #expect(error?.description == message)
        #expect(await system.writes == 0)
    }

    @Test("An irreversible verb is refused unless destructive actions are allowed, and nothing is done")
    func irreversible() async throws {
        let store = FakeEventStore()
        let event = StoreEvent(id: "e1", title: "Braus test", start: Date(), end: Date().addingTimeInterval(3600),
                               isAllDay: false, calendarID: "home")
        await store.add(event)
        let refused = try await Self.adapters(store: store).call(app: "calendar", verb: "delete_event",
                                                                 arguments: .object(["id": .string("e1")]))
        #expect(refused.kind == .refused)
        #expect(await store.events.count == 1)
        let deleted = try await Self.adapters(store: store, allowsIrreversible: true)
            .call(app: "calendar", verb: "delete_event", arguments: .object(["id": .string("e1")]))
        // R07: confirmed only by its read-back, and the effect is there: the event is gone from the store.
        #expect(deleted.kind == .foundActed && deleted.confirmedByReadBack)
        #expect(await store.events.isEmpty)
    }

    /// ScriptedAdapter offers one irreversible verb, `purge`, declared with `confirms` and answering confirmed either
    /// through `afterChange` (as a verb that reads its change back) or straight away; it counts its calls.
    final class ScriptedAdapter: AppAdapting, @unchecked Sendable {
        let name = "scripted"
        let appNames = ["Scripted"]
        let bundleIDs: Set<String> = ["test.scripted"]
        let verbs: [AdapterVerb]
        let readsBack: Bool
        private(set) var calls = 0

        init(confirms: AdapterVerb.Confirmation, readsBack: Bool) {
            verbs = [AdapterVerb("purge", "Purges everything.", safety: .irreversible, readBack: "the store emptied",
                                 confirms: confirms)]
            self.readsBack = readsBack
        }

        func availability() async -> AdapterAvailability { .ready }
        func requestPermission() async -> AdapterAvailability { .ready }
        func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
            calls += 1
            guard readsBack else { return .confirmed("Purged.") }
            return await .afterChange("Purged", look: "Read the store") {
                .confirmed("Purged, and the store reads empty.")
            }
        }
    }

    @Test("R07: an irreversible verb that declares no read-back contract is refused, even with the person's consent")
    func irreversibleWithoutContract() async throws {
        let undeclared = ScriptedAdapter(confirms: .none, readsBack: true)
        let refused = try await AppAdapters([undeclared], allowsIrreversible: true)
            .call(app: "scripted", verb: "purge", arguments: .null)
        #expect(refused.kind == .refused && refused.message.contains("cannot read its effect back"),
                Comment(rawValue: refused.message))
        let unconsented = try await AppAdapters([ScriptedAdapter(confirms: .readBack, readsBack: true)])
            .call(app: "scripted", verb: "purge", arguments: .null)
        #expect(unconsented.kind == .refused && unconsented.message.contains("destructive actions are off"))
        #expect(undeclared.calls == 0)
    }

    @Test("R07: a confirmed answer its read-back did not give is not a confirmation: it may have happened")
    func confirmationCheckedInTheResult() async throws {
        let liar = ScriptedAdapter(confirms: .readBack, readsBack: false)
        let outcome = try await AppAdapters([liar], allowsIrreversible: true).call(app: "scripted", verb: "purge",
                                                                                   arguments: .null)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("without reading its change back"),
                Comment(rawValue: outcome.message))
        #expect(liar.calls == 1, "it ran once, and nothing is repeated")
        let truthful = AppAdapters([ScriptedAdapter(confirms: .readBack, readsBack: true)], allowsIrreversible: true)
        let honest = try await truthful.call(app: "scripted", verb: "purge", arguments: .null)
        #expect(honest.kind == .foundActed && honest.confirmedByReadBack)
    }

    @Test("An adapter without its permission refuses with how to grant it, and never runs")
    func permission() async throws {
        let store = FakeEventStore(grants: [.events: .notDetermined, .reminders: .denied])
        let outcome = try await Self.adapters(store: store).call(app: "Calendar", verb: "list_calendars", arguments: .null)
        #expect(outcome.kind == .refused)
        #expect(outcome.message.contains("Privacy & Security > Calendars"))
        let capabilities = await Self.adapters(store: store).capabilities(of: "Reminders", query: nil)
        #expect(capabilities["availability"]["state"] == .string("needs_permission"))
    }

    @Test("Capabilities filter verbs by the words of a query")
    func capabilities() async {
        let listing = await Self.adapters().capabilities(of: "calendar", query: "create event")
        let verbs = listing["verbs"].array?.compactMap { $0["verb"].string }
        #expect(verbs == ["calendar.create_event"])
        #expect(listing["verbs"].array?.first?["safety"] == .string("write"))
        let unknown = await Self.adapters().capabilities(of: "Pages", query: nil)
        #expect(unknown["adapter"] == .null)
    }

    @Test("Every adapter of the build names a read-back for every verb, and no verb twice")
    func standardVerbs() {
        for adapter in AppAdapters.standard().adapters {
            let names = adapter.verbs.map(\.name)
            #expect(Set(names).count == names.count, "\(adapter.name) repeats a verb")
            for verb in adapter.verbs { #expect(!verb.readBack.isEmpty, "\(adapter.name).\(verb.name)") }
            // R07: every irreversible verb of the build runs under the read-back contract.
            for verb in adapter.verbs where verb.safety == .irreversible {
                #expect(verb.confirmation == .readBack, "\(adapter.name).\(verb.name)")
            }
        }
    }
}
