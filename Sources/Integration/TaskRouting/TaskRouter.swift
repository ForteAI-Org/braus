import Foundation

/// TaskRouter applies the routing rules when an agent opens an app: a named app is used as named; a
/// native app the catalogue has a better route for is answered with that route; everything else
/// opens as asked. It never opens anything and holds no state: what it knows of the Mac (the adapters
/// ready, the accounts signed in) comes in a `RouteContext` for each decision.
///
/// The rules are general: nothing in them depends on the person, their country or their language
/// (spec 2026-10-14-mac-driver-design, section 2).
public struct TaskRouter: Sendable {

    public let catalogue: RouteCatalogue

    public init(catalogue: RouteCatalogue = .standard) {
        self.catalogue = catalogue
    }

    /// Resolve identity before routing; a localized display name never selects an unrelated service.
    public func route(opening app: String, bundleID: String?, named: Bool,
                      context: RouteContext) -> RouteDecision {
        guard !named, let bundleID, bundleID.contains(".") else { return .open(note: nil) }
        let result = route(opening: bundleID, named: false, context: context)
        func shown(_ text: String) -> String { text.replacingOccurrences(of: bundleID, with: app) }
        switch result {
            case .use(let route, let message): return .use(route, message: shown(message))
            case .ask(let message): return .ask(shown(message))
            case .open(let message): return .open(note: message.map(shown))
        }
    }

    public func route(opening app: String, bundleID: String?, named: Bool, offersWeb: Bool = false,
                      availability: (String) async -> RouteAvailability?) async -> RouteDecision {
        guard !named, let bundleID, bundleID.contains(".") else { return .open(note: nil) }
        var context = RouteContext(webAvailable: offersWeb)
        if let adapter = catalogue.adapter(replacing: bundleID) {
            guard let state = await availability(adapter) else { return .open(note: nil) }
            context.adapters[adapter] = state
        }
        return route(opening: app, bundleID: bundleID, named: named, context: context)
    }

    /// The decision for opening `app`. `named` is true when the person named that app or service
    /// (rule 1): "the X app" or its brand, never a kind of thing like "maps" (`SharedRoutes.namedApp`).
    /// A named app is opened as asked, whatever the catalogue says.
    public func route(opening app: String, named: Bool, context: RouteContext = RouteContext()) -> RouteDecision {
        let trimmed = app.trimmingCharacters(in: .whitespaces)
        if named || Self.isWebAddress(trimmed) { return .open(note: nil) }
        guard let entry = catalogue.entry(replacing: trimmed) else { return .open(note: nil) }
        switch entry.route {
            // R02: a web route only where a web page can be opened; else the app opens as asked.
            case .web where !context.webAvailable, .webMail where !context.webAvailable:
                return .open(note: nil)
            case .web(let host):
                return webDecision(app: trimmed, host: host, entry: entry, context: context)
            case .webMail:
                guard let host = context.mailHost else {
                    return .ask("\(trimmed): " + SharedRoutes.mailAccount)
                }
                return webDecision(app: trimmed, host: host, entry: entry, context: context)
            case .adapter(let name):
                // Rule 3: an adapter that cannot run now is skipped, with its reason, for the interface.
                guard let availability = context.adapters[name] else {
                    return .open(note: "\(trimmed) has no \(name) adapter in this build yet: driving its interface.")
                }
                if case .notReady(let reason) = availability {
                    return .open(note: "The \(name) adapter cannot run (\(reason)): driving \(trimmed)'s interface "
                                 + "instead.")
                }
                // R04: a grant not known yet is not readiness. The adapter stays the route, since its verb checks the
                // grant before any event reaches the app, and the answer says so.
                let unknown = availability.reason.map { " Whether it may run is not known yet (\($0)): its verb checks "
                    + "that first and refuses before acting if it may not." } ?? ""
                return .use(entry.route, message: "\(trimmed): use app_call with app \"\(name)\"; app_capabilities "
                            + "lists its verbs. It works with \(trimmed) closed.\(unknown) "
                            + SharedRoutes.openOnlyIfNamed(trimmed)
                            + " When none of its verbs does the task, call open_session again with named true to drive the interface.")
            case .perContact:
                return .open(note: SharedRoutes.messageChannel + " " + SharedRoutes.whatsApp)
        }
    }

    /// Rule 7: a web route that needs an account not signed in answers how to connect it, once, and
    /// does not switch route by itself. When whether it is signed in is not known, the route is used and the
    /// answer says so: an unknown login is neither readiness nor a missing one, and nothing prompts (R04).
    private func webDecision(app: String, host: String, entry: RouteEntry, context: RouteContext) -> RouteDecision {
        let route = Route.web(host)
        if entry.needsLogin, let signedIn = context.signedInHosts, !signedIn.contains(Self.site(of: host)) {
            return .ask("\(app): this goes through \(route.address), which needs an account that is not signed in "
                        + "in Braus's browser profile. Tell the person to sign in once at https://\(host) in "
                        + "Braus's Chrome window, then try again.")
        }
        let unknown = entry.needsLogin && context.signedInHosts == nil
            ? " Whether its account is signed in in Braus's browser profile is not known: if the page asks to sign in, "
                + "tell the person to sign in once at https://\(host) in Braus's Chrome window; never sign in for them."
            : ""
        return .use(route, message: "\(app): call open_session with app \"web:\(host)\", which does the task in Braus's browser.\(unknown) "
                    + SharedRoutes.openOnlyIfNamed(app) + " When the page cannot do the task, call open_session again with named true.")
    }

    /// Whether the text names a web address the web session takes: `web:<host>` or a URL.
    static func isWebAddress(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("web:") || lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    /// The host part of an address, for comparing with the signed-in hosts: `mail.google.com/x` gives
    /// `mail.google.com`.
    static func site(of host: String) -> String {
        String(host.prefix { $0 != "/" && $0 != "?" }).lowercased()
    }

    // MARK: Rungs

    /// The order a task's routes are tried in, from the most background (rule 3). A route is skipped
    /// only with a reason.
    public static let backgroundOrder: [Rung] = [.web, .adapter, .accessibility, .backgroundKeyWindow, .seat, .foreground]

    /// Rule 4: whether an irreversible step (send, delete, pay) may end on this rung, as the policy stands
    /// (`IrreversiblePolicy`): only an adapter verb that reads its own change back. A page read again is no
    /// verifier of a send, so the web, like every rung the engine drives, may not.
    public static func mayFinishIrreversible(on rung: Rung) -> Bool {
        rung == .adapter
    }
}

/// Rung is one way of reaching an app, from the most background.
public enum Rung: String, Sendable, Equatable, CaseIterable {
    case web, adapter, accessibility
    /// The MacDriver's mode 2: key-window records on the target window, the app behind.
    case backgroundKeyWindow = "background_key_window"
    /// Mode 1: the app on the Seat's virtual display.
    case seat
    /// Mode 3: the app in front, under the foreground policy.
    case foreground
}

/// RouteContext is what the router knows of the Mac for one decision.
public struct RouteContext: Sendable, Equatable {

    /// The adapters of this build by name, with whether each can run now.
    public var adapters: [String: RouteAvailability]
    /// The hosts signed in in Braus's browser profile; nil when unknown, which never blocks a route.
    public var signedInHosts: Set<String>?
    /// The host of the person's web mail, when the memory knows it.
    public var mailHost: String?
    /// Whether this run can open a web page; without, no web route is offered (R02).
    public var webAvailable: Bool

    public init(adapters: [String: RouteAvailability] = [:], signedInHosts: Set<String>? = nil, mailHost: String? = nil,
                webAvailable: Bool = true) {
        self.adapters      = adapters
        self.signedInHosts = signedInHosts
        self.mailHost      = mailHost
        self.webAvailable  = webAvailable
    }
}

/// RouteAvailability is an adapter's availability as the router needs it: ready, not ready with why, or not known
/// yet (a grant the app cannot answer while it is not running), which is not readiness (R04).
public enum RouteAvailability: Sendable, Equatable {
    case ready
    case notReady(String)
    case unknown(String)

    public var isReady: Bool { self == .ready }

    public var reason: String? {
        switch self {
            case .ready                                       : nil
            case .notReady(let reason), .unknown(let reason): reason
        }
    }
}

/// RouteDecision is what the router answers to opening an app.
public enum RouteDecision: Sendable, Equatable {
    /// Open the app as asked; the note, when there is one, goes to the agent with the result.
    case open(note: String?)
    /// Do not open the app: use this route, as the message tells the agent.
    case use(Route, message: String)
    /// Do not open anything yet: the message says what to ask or tell the person.
    case ask(String)
}
