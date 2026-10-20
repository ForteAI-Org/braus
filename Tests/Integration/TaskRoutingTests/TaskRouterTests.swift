import Testing
import TaskRouting

/// The router's rules on their own: named wins, web addresses pass, native apps with a better route
/// are answered with it, an adapter that cannot run is skipped with its reason, a missing login is
/// said once, irreversible steps end only on a rung that reads back.
@Suite("Task router: the routing rules and the catalogue")
struct TaskRouterTests {

    let router = TaskRouter()
    let ready  = RouteContext(adapters: ["calendar": .ready, "reminders": .ready, "files": .ready, "system": .ready])

    @Test("Rule 1: an app the person named opens as asked", arguments: ["Maps", "Calendar", "Mail", "Messages"])
    func named(app: String) {
        #expect(router.route(opening: app, named: true, context: ready) == .open(note: nil))
    }

    @Test("R01: every app or service the catalogue would route elsewhere opens as asked once the person named it, whatever is ready, signed in or known")
    func namedNeverReplaced() {
        let adapters: [String: RouteAvailability] = ["calendar": .ready, "reminders": .ready, "notes": .ready,
                                                     "files": .ready, "system": .ready]
        let everything = RouteContext(adapters: adapters,
                                      signedInHosts: ["mail.google.com", "google.com"], mailHost: "mail.google.com")
        var withoutWeb = everything
        withoutWeb.webAvailable = false
        for entry in router.catalogue.entries {
            for name in entry.replaces {
                for context in [everything, withoutWeb, RouteContext()] {
                    #expect(router.route(opening: name, named: true, context: context) == .open(note: nil), "\(name)")
                }
            }
        }
    }

    @Test("R02: without a web session no web route is offered, so the app opens as asked; an adapter that can run still is")
    func noWebRouteWithoutTheWeb() {
        var context = ready
        context.webAvailable = false
        for entry in router.catalogue.entries {
            for name in entry.replaces {
                switch entry.route {
                    case .web, .webMail:
                        #expect(router.route(opening: name, named: false, context: context) == .open(note: nil),
                                "\(name)")
                    case .adapter(let adapter) where context.adapters[adapter] == .ready:
                        guard case .use(.adapter(adapter), _) = router.route(opening: name, named: false,
                                                                            context: context) else {
                            Issue.record("\(name) did not go to its ready adapter without the web")
                            continue
                        }
                    case .adapter, .perContact:
                        continue
                }
            }
        }
    }

    @Test("Rule 1: a kind of thing is not a name, so it takes the default route; the brand opens the app",
          arguments: ["Mappe", "Maps"])
    func kindVersusBrand(app: String) {
        // "cercami il Duomo con Mappe": the agent leaves named false and gets Google Maps on the web.
        guard case .use(let route, let message) = router.route(opening: app, named: false, context: ready) else {
            Issue.record("\(app) as a kind of thing was not redirected")
            return
        }
        #expect(route == .web("google.com/maps"))
        #expect(message.contains("\"the \(app) app\" or its brand"))
        // "apri l'app Mappe", "Mappe di Apple", "Apple Maps": named, opened as asked.
        #expect(router.route(opening: app, named: true, context: ready) == .open(note: nil))
    }

    @Test("Rule 1's wording separates a kind of thing from an app's name or brand")
    func namedWording() {
        for kind in ["\"mappe\"", "\"weather\"", "\"translator\"", "\"calendar\"", "\"with Maps\""] {
            #expect(SharedRoutes.namedApp.contains(kind))
        }
        #expect(SharedRoutes.namedApp.contains("\"the X app\" or its brand"))
        #expect(SharedRoutes.namedApp.contains("leave named false"))
    }

    @Test("Web addresses and apps the catalogue does not know open as asked",
          arguments: ["web:google.com/maps", "https://example.com", "Pages", "com.adobe.Photoshop"])
    func passes(app: String) {
        #expect(router.route(opening: app, named: false, context: ready) == .open(note: nil))
    }

    @Test("A native app with a web route is answered with it, by name or bundle id",
          arguments: [("Maps", "google.com/maps"), ("com.apple.Maps", "google.com/maps"), ("Mappe.app", "google.com/maps"),
                      ("Translate", "translate.google.com"), ("TV", "youtube.com")])
    func web(app: String, host: String) {
        guard case .use(let route, let message) = router.route(opening: app, named: false, context: ready) else {
            Issue.record("\(app) was not redirected")
            return
        }
        #expect(route == .web(host))
        #expect(message.contains("web:\(host)"))
    }

    @Test("A store the Mac syncs goes to its adapter when it is ready", arguments: [
        ("Calendar", "calendar"), ("Promemoria", "reminders"), ("Finder", "files"), ("System Settings", "system"),
    ])
    func adapter(app: String, adapter: String) {
        guard case .use(let route, let message) = router.route(opening: app, named: false, context: ready) else {
            Issue.record("\(app) was not redirected")
            return
        }
        #expect(route == .adapter(adapter))
        #expect(message.contains("app_call"))
    }

    @Test("Rule 3: an adapter that cannot run, or is not built yet, is skipped with its reason")
    func skipped() {
        let context = RouteContext(adapters: ["calendar": .notReady("no Calendars access")])
        guard case .open(let note?) = router.route(opening: "Calendar", named: false, context: context) else {
            Issue.record("Calendar was not opened with a note")
            return
        }
        #expect(note.contains("no Calendars access"))
        guard case .open(let missing?) = router.route(opening: "Notes", named: false, context: context) else {
            Issue.record("Notes was not opened with a note")
            return
        }
        #expect(missing.contains("no notes adapter"))
    }

    @Test("Mail goes to the account's web mail; unknown account asks, a host not signed in says how to connect")
    func mail() {
        let router = TaskRouter(catalogue: RouteCatalogue([RouteEntry(.mail, .webMail, replaces: ["Mail"], needsLogin: true)]))
        guard case .ask(let which) = router.route(opening: "Mail", named: false, context: ready) else {
            Issue.record("Mail without an account did not ask")
            return
        }
        #expect(which.contains("which account"))
        let signedIn = RouteContext(signedInHosts: ["mail.google.com"], mailHost: "mail.google.com")
        guard case .use(.web("mail.google.com"), _) = router.route(opening: "Mail", named: false, context: signedIn) else {
            Issue.record("the explicit webmail route did not use the chosen account")
            return
        }
        let signedOut = RouteContext(signedInHosts: [], mailHost: "outlook.live.com/mail")
        guard case .ask(let connect) = router.route(opening: "Mail", named: false, context: signedOut) else {
            Issue.record("Mail signed out did not say how to connect")
            return
        }
        #expect(connect.contains("https://outlook.live.com/mail"))
        let unknown = RouteContext(signedInHosts: nil, mailHost: "mail.google.com")
        // R04: an unknown login is neither readiness nor a missing one: the route is used, and the answer says so.
        let routed = router.route(opening: "Mail", named: false, context: unknown)
        guard case .use(.web("mail.google.com"), let note) = routed else {
            Issue.record("Mail with an unknown login was not routed to its web mail")
            return
        }
        #expect(note.contains("is not known") && note.contains("never sign in for them"), "\(note)")
        guard case .use(_, let known) = router.route(opening: "Mail", named: false, context: signedIn) else { return }
        #expect(!known.contains("is not known"), "a known login says nothing of it")
    }

    @Test("R04: an adapter whose grant is not known yet is not ready: it stays the route, and the answer says so")
    func adapterUnknown() {
        let unknown = RouteContext(adapters: ["calendar": .unknown("Calendar is not running")])
        guard case .use(.adapter("calendar"), let message) = router.route(opening: "Calendar", named: false,
                                                                          context: unknown) else {
            Issue.record("an unknown grant did not keep the adapter")
            return
        }
        #expect(message.contains("is not known yet (Calendar is not running)") && message.contains("refuses before"),
                "\(message)")
        #expect(!RouteAvailability.unknown("x").isReady)
        let ready = RouteContext(adapters: ["calendar": .ready])
        guard case .use(_, let plain) = router.route(opening: "Calendar", named: false, context: ready) else { return }
        #expect(!plain.contains("is not known"))
    }

    @Test("Rule 5: messages open as asked, with the per-contact channel rule")
    func messages() {
        guard case .open(let note?) = router.route(opening: "WhatsApp", named: false, context: ready) else {
            Issue.record("WhatsApp did not open with a note")
            return
        }
        #expect(note.contains("last time"))
    }

    @Test("Rule 4: an irreversible step ends only on an adapter verb that reads its change back, never the web")
    func irreversible() {
        #expect(TaskRouter.backgroundOrder == Rung.allCases)
        #expect(Rung.allCases.filter(TaskRouter.mayFinishIrreversible) == [.adapter])
    }

    @Test("The catalogue has one entry per kind and no native app under two kinds")
    func catalogue() {
        let entries = RouteCatalogue.standard.entries
        #expect(Set(entries.map(\.kind)) == Set(TaskKind.allCases))
        #expect(entries.count == TaskKind.allCases.count)
        let replaced = entries.flatMap(\.replaces).map { $0.lowercased() }
        #expect(Set(replaced).count == replaced.count)
    }

}
