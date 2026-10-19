import Foundation

/// TaskRouter applies the routing rules when an agent opens an app: a named app is used as named (rule 1); a
/// native app the catalogue has a website for is answered with that website, when the web session is composed; one
/// it has an adapter for is answered with that adapter, when the composition has it and it can run; everything else
/// opens as asked. It never opens anything and holds no state.
///
/// The rules are general: nothing in them depends on the person, their country or their language. The app is
/// matched by the bundle id the resolver gave its name, so a localized name routes as the app's own does.
public struct TaskRouter: Sendable {

    public let catalogue: RouteCatalogue

    public init(catalogue: RouteCatalogue = .standard) {
        self.catalogue = catalogue
    }

    /// The decision for opening `app`, the name the agent wrote, which the resolver turned into `bundleID` (nil when
    /// it named no single application). `named` is true when the person named that app (rule 1,
    /// `SharedRoutes.namedApp`): a named app opens as asked, whatever the catalogue says. `availability` answers
    /// whether the adapter of that name can run, nil when the composition has no such adapter, which opens the app
    /// as asked and says nothing; it is asked only for the adapter the catalogue names. `offersWeb` is true when the
    /// web session is composed, which opens the catalogue's websites; without it nothing routes to the web.
    public func route(
        opening app : String,
        bundleID    : String?,
        named       : Bool,
        offersWeb   : Bool = false,
        availability: (String) async -> RouteAvailability?
    ) async -> RouteDecision {
        let shown = app.trimmingCharacters(in: .whitespaces)
        guard !named, let bundleID else { return .open(note: nil) }
        if offersWeb, let host = catalogue.website(replacing: bundleID) {
            return .use(.web(host), message: "\(shown): call open_session with app \"web:\(host)\", which does the "
                        + "task in Braus's own browser without \(shown). " + SharedRoutes.openOnlyIfNamed(shown)
                        + " When the page cannot do the task, call open_session again with named true to drive "
                        + "\(shown)'s interface.")
        }
        guard let name = catalogue.adapter(replacing: bundleID),
              let state = await availability(name) else { return .open(note: nil) }
        // Rule 3: an adapter that cannot run now is skipped, with its reason, for the interface.
        if case .notReady(let reason) = state {
            return .open(note: "The \(name) adapter cannot run (\(reason)): driving \(shown)'s interface instead.")
        }
        // R04: a grant not known yet is not readiness. The adapter stays the route, since its verb checks the grant
        // before any event reaches the app, and the answer says so.
        let unknown = state.reason.map { " Whether it may run is not known yet (\($0)): its verb checks that first "
            + "and refuses before acting if it may not." } ?? ""
        return .use(.adapter(name), message: "\(shown): use app_call with app \"\(name)\"; app_capabilities lists "
                    + "its verbs. It works with \(shown) closed.\(unknown) " + SharedRoutes.openOnlyIfNamed(shown)
                    + " When none of its verbs does the task, call open_session again with named true to drive "
                    + "\(shown)'s interface.")
    }
}

/// RouteAvailability is an adapter's availability as the router needs it: ready, not ready with why, or not known
/// yet (a grant the app cannot answer while it is not running), which is not readiness (R04).
public enum RouteAvailability: Sendable, Equatable {
    case ready
    case notReady(String)
    case unknown(String)

    public var reason: String? {
        switch self {
            case .ready                                     : nil
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
}
