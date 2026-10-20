import Foundation

/// RouteCatalogue is the default route for each kind of task, the same for everyone: which service or
/// adapter does the task, which native apps it stands in for, and whether it needs an account. It is
/// data, read by `TaskRouter`; the memory corrects it per app as outcomes come in.
///
/// Independent from the sessions, the adapters and the memory: it names them by text only.
public struct RouteCatalogue: Sendable, Equatable {

    public let entries: [RouteEntry]

    public init(_ entries: [RouteEntry]) {
        self.entries = entries
    }

    public func entry(for kind: TaskKind) -> RouteEntry? {
        entries.first { $0.kind == kind }
    }

    /// The entry whose route stands in for a native app, named by its name or its bundle id without
    /// case and without `.app`.
    public func entry(replacing app: String) -> RouteEntry? {
        let wanted = Self.normalized(app)
        return entries.first { entry in entry.replaces.contains { Self.normalized($0) == wanted } }
    }

    public var adapters: [String: String] {
        entries.reduce(into: [:]) { result, entry in
            guard case .adapter(let name) = entry.route else { return }
            for id in entry.replaces where id.contains(".") { result[id] = name }
        }
    }

    public var websites: [String: String] {
        entries.reduce(into: [:]) { result, entry in
            guard case .web(let host) = entry.route else { return }
            for id in entry.replaces where id.contains(".") { result[id] = host }
        }
    }

    public func adapter(replacing bundleID: String) -> String? {
        adapters.first { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }?.value
    }

    public func website(replacing bundleID: String) -> String? {
        websites.first { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }?.value
    }

    static func normalized(_ app: String) -> String {
        var name = app.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name
    }
}

/// TaskKind is a kind of task the catalogue has a default route for.
public enum TaskKind: String, Sendable, Equatable, CaseIterable {
    case places, search, translation, weather, stocks, news, video
    case mail, calendar, reminders, notes, files, macSettings = "mac_settings", messages
}

/// Route is where a task goes.
public enum Route: Sendable, Equatable {
    /// A website through the WebDriver, by its address without scheme: `google.com/maps`.
    case web(String)
    /// The web mail of the person's account, whose host the caller knows (`mail.google.com`).
    case webMail
    /// An app adapter, by its name: `calendar`, `files`.
    case adapter(String)
    /// The channel that worked last time with the contact, from the memory (rule 5).
    case perContact

    /// The route as the agent writes it.
    public var address: String {
        switch self {
            case .web(let host)     : "web:\(host)"
            case .webMail           : "web mail"
            case .adapter(let name) : "app_call(\(name))"
            case .perContact        : "the contact's channel"
        }
    }
}

/// RouteEntry is one line of the catalogue.
public struct RouteEntry: Sendable, Equatable {
    public let kind      : TaskKind
    public let route     : Route
    /// The native apps the route stands in for, by name and bundle id.
    public let replaces  : [String]
    /// Whether the route needs an account signed in where it runs.
    public let needsLogin: Bool

    public init(_ kind: TaskKind, _ route: Route, replaces: [String], needsLogin: Bool = false) {
        self.kind       = kind
        self.route      = route
        self.replaces   = replaces
        self.needsLogin = needsLogin
    }
}

extension RouteCatalogue {

    /// The first entries (spec 2026-10-14-mac-driver-design, section 2).
    public static let standard = RouteCatalogue([
        RouteEntry(.places, .web("google.com/maps"), replaces: ["Maps", "Mappe", "com.apple.Maps"]),
        RouteEntry(.search, .web("google.com"), replaces: ["Safari", "com.apple.Safari"]),
        RouteEntry(.translation, .web("translate.google.com"), replaces: ["Translate", "Traduci", "com.apple.Translate"]),
        RouteEntry(.weather, .web("google.com/search?q=weather"), replaces: ["Weather", "Meteo", "com.apple.weather"]),
        RouteEntry(.stocks, .web("google.com/finance"), replaces: ["Stocks", "Borsa", "com.apple.stocks"]),
        RouteEntry(.news, .web("news.google.com"), replaces: ["News", "com.apple.news"]),
        RouteEntry(.video, .web("youtube.com"), replaces: ["TV", "com.apple.TV"]),
        RouteEntry(.mail, .adapter("mail"), replaces: ["Mail", "com.apple.mail"]),
        RouteEntry(.calendar, .adapter("calendar"), replaces: ["Calendar", "Calendario", "com.apple.iCal"]),
        RouteEntry(.reminders, .adapter("reminders"), replaces: ["Reminders", "Promemoria", "com.apple.reminders"]),
        RouteEntry(.notes, .adapter("notes"), replaces: ["Notes", "Note", "com.apple.Notes"]),
        RouteEntry(.files, .adapter("files"), replaces: ["Finder", "com.apple.finder"]),
        RouteEntry(.macSettings, .adapter("system"),
                   replaces: ["System Settings", "Impostazioni di Sistema", "com.apple.systempreferences"]),
        RouteEntry(.messages, .perContact, replaces: ["Messages", "Messaggi", "com.apple.MobileSMS", "WhatsApp",
                                                      "net.whatsapp.WhatsApp"]),
    ])
}
