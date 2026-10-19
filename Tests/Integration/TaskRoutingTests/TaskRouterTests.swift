import TaskRouting
import Testing

/// The router's rules on their own: named wins; a native app the catalogue knows, by the bundle id the resolver gave
/// it, goes to its adapter when the composition has it and it can run; anything else opens as asked.
@Suite("Task router: the routing rules and the catalogue")
struct TaskRouterTests {

    let router = TaskRouter()

    static let everyAdapter: [String: RouteAvailability] = [
        "calendar": .ready, "reminders": .ready, "notes": .ready, "files": .ready, "system": .ready, "mail": .ready,
    ]

    /// The decision with these adapters composed.
    func route(_ app: String, _ bundleID: String?, named: Bool = false,
               adapters: [String: RouteAvailability] = everyAdapter) async -> RouteDecision {
        await router.route(opening: app, bundleID: bundleID, named: named) { adapters[$0] }
    }

    @Test("The catalogue sends each native app, by its bundle id in any case, to its adapter", arguments: [
        ("com.apple.iCal", "calendar"), ("com.apple.reminders", "reminders"), ("com.apple.Notes", "notes"),
        ("com.apple.finder", "files"), ("com.apple.systempreferences", "system"), ("com.apple.mail", "mail"),
        ("COM.APPLE.ICAL", "calendar"),
    ])
    func catalogue(bundleID: String, adapter: String) async {
        guard case .use(let route, let message) = await route("Calendario", bundleID) else {
            Issue.record("\(bundleID) was not routed")
            return
        }
        #expect(route == .adapter(adapter) && route.address == "app_call(\(adapter))")
        #expect(message.hasPrefix("Calendario: use app_call with app \"\(adapter)\""), "\(message)")
        #expect(message.contains(SharedRoutes.openOnlyIfNamed("Calendario")))
        #expect(message.contains("When none of its verbs does the task, call open_session again with named true"))
        #expect(!message.contains("is not known"), "a ready adapter says nothing of its grant")
    }

    @Test("Rule 1: an app the person named opens as asked, whatever is composed and ready")
    func named() async {
        for bundleID in router.catalogue.adapters.keys {
            #expect(await route("App", bundleID, named: true) == .open(note: nil), "\(bundleID)")
        }
    }

    @Test("Only the bundle id routes: an unresolved name or an unknown app opens as asked, no adapter asked about")
    func passes() async {
        var asked: [String] = []
        for (app, bundleID) in [("Calendar", nil), ("Calendar", "Calendar"), ("Pages", "com.apple.iWork.Pages"),
                                ("Photoshop", "com.adobe.Photoshop")] as [(String, String?)] {
            let decision = await router.route(opening: app, bundleID: bundleID, named: false) { name in
                asked.append(name)
                return .ready
            }
            #expect(decision == .open(note: nil), "\(app)")
        }
        #expect(asked.isEmpty)
    }

    @Test("Without the adapter in the composition the app opens as asked and nothing is said; only its adapter is asked")
    func notComposed() async {
        var asked: [String] = []
        let decision = await router.route(opening: "Calendar", bundleID: "com.apple.iCal", named: false) { name in
            asked.append(name)
            return nil
        }
        #expect(decision == .open(note: nil))
        #expect(asked == ["calendar"])
        #expect(await route("Notes", "com.apple.Notes", adapters: ["calendar": .ready]) == .open(note: nil))
    }

    @Test("Rule 3: an adapter that cannot run is skipped for the interface, with its reason")
    func skipped() async {
        let decision = await route("Calendar", "com.apple.iCal", adapters: ["calendar": .notReady("no Calendars access")])
        #expect(decision == .open(note: "The calendar adapter cannot run (no Calendars access): driving Calendar's "
                                  + "interface instead."))
    }

    @Test("R04: an adapter whose grant is not known yet is not ready: it stays the route, and the answer says so")
    func unknownGrant() async {
        guard case .use(.adapter("notes"), let message) = await route(
            "Notes", "com.apple.Notes", adapters: ["notes": .unknown("Notes is not running")]
        ) else {
            Issue.record("an unknown grant did not keep the adapter")
            return
        }
        #expect(message.contains("is not known yet (Notes is not running)") && message.contains("refuses before"),
                "\(message)")
    }

    @Test("Rule 1's wording separates a kind of thing from an app's name or brand")
    func namedWording() {
        for kind in ["\"mappe\"", "\"weather\"", "\"translator\"", "\"calendar\"", "\"with Maps\""] {
            #expect(SharedRoutes.namedApp.contains(kind))
        }
        #expect(SharedRoutes.namedApp.contains("\"the X app\" or its brand"))
        #expect(SharedRoutes.namedApp.contains("leave named false"))
    }
}
