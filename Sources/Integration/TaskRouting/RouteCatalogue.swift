import Foundation

/// RouteCatalogue is the default route for the native apps a kind of thing is done in, the same for everyone: the
/// app adapter that does it in the app's place, or the website that does it when the web session is composed, by the
/// app's bundle id. It is data, read by `TaskRouter`.
///
/// It matches a bundle id, never a name: the resolver that opens an app turns the name the agent wrote, in any of
/// the app's names and the person's language, into the bundle id first. Independent from the sessions, the adapters
/// and the memory: it names an adapter by text only.
public struct RouteCatalogue: Sendable, Equatable {

    /// The adapter of each native app, by bundle id as written in the app's bundle.
    public let adapters: [String: String]
    /// The website, by its address without scheme, that does what each native app does, by bundle id.
    public let websites: [String: String]

    public init(_ adapters: [String: String], websites: [String: String] = [:]) {
        self.adapters = adapters
        self.websites = websites
    }

    /// The adapter that stands in for the app of `bundleID`, compared without case; nil when none does.
    public func adapter(replacing bundleID: String) -> String? {
        Self.value(of: bundleID, in: adapters)
    }

    /// The website that stands in for the app of `bundleID`, compared without case; nil when none does.
    public func website(replacing bundleID: String) -> String? {
        Self.value(of: bundleID, in: websites)
    }

    private static func value(of bundleID: String, in table: [String: String]) -> String? {
        let wanted = bundleID.trimmingCharacters(in: .whitespaces)
        return table.first { $0.key.caseInsensitiveCompare(wanted) == .orderedSame }?.value
    }
}

/// Route is where a task goes instead of the app's interface.
public enum Route: Sendable, Equatable {
    /// An app adapter, by its name: `calendar`, `files`.
    case adapter(String)
    /// A website in the web session, by its address without scheme: `google.com/maps`.
    case web(String)

    /// The route as the agent writes it.
    public var address: String {
        switch self {
            case .adapter(let name): "app_call(\(name))"
            case .web(let host)    : "web:\(host)"
        }
    }
}

extension RouteCatalogue {

    /// The apps whose data lives on the Mac and that an adapter of this build reads and changes with the app closed.
    /// System Settings goes to the `system` adapter, which has only a few of its settings: the advice says how to
    /// reach the interface when none of its verbs does the task. The apps whose task a public website does go there
    /// when the web session is composed; Mail stays on its adapter, since web mail needs the person's account.
    public static let standard = RouteCatalogue([
        "com.apple.iCal"              : "calendar",
        "com.apple.reminders"         : "reminders",
        "com.apple.Notes"             : "notes",
        "com.apple.finder"            : "files",
        "com.apple.systempreferences" : "system",
        "com.apple.mail"              : "mail",
    ], websites: [
        "com.apple.Maps"      : "google.com/maps",
        "com.apple.Translate" : "translate.google.com",
        "com.apple.weather"   : "google.com/search?q=weather",
        "com.apple.stocks"    : "google.com/finance",
        "com.apple.news"      : "news.google.com",
        "com.apple.TV"        : "youtube.com",
    ])
}
