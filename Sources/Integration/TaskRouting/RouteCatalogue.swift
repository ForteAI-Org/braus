import Foundation

/// RouteCatalogue is the default route for the native apps a kind of thing is done in, the same for everyone: the
/// app adapter that does it in the app's place, by the app's bundle id. It is data, read by `TaskRouter`.
///
/// It matches a bundle id, never a name: the resolver that opens an app turns the name the agent wrote, in any of
/// the app's names and the person's language, into the bundle id first. Independent from the sessions, the adapters
/// and the memory: it names an adapter by text only.
public struct RouteCatalogue: Sendable, Equatable {

    /// The adapter of each native app, by bundle id as written in the app's bundle.
    public let adapters: [String: String]

    public init(_ adapters: [String: String]) {
        self.adapters = adapters
    }

    /// The adapter that stands in for the app of `bundleID`, compared without case; nil when none does.
    public func adapter(replacing bundleID: String) -> String? {
        let wanted = bundleID.trimmingCharacters(in: .whitespaces)
        return adapters.first { $0.key.caseInsensitiveCompare(wanted) == .orderedSame }?.value
    }
}

/// Route is where a task goes instead of the app's interface.
public enum Route: Sendable, Equatable {
    /// An app adapter, by its name: `calendar`, `files`.
    case adapter(String)

    /// The route as the agent writes it.
    public var address: String {
        switch self {
            case .adapter(let name): "app_call(\(name))"
        }
    }
}

extension RouteCatalogue {

    /// The apps whose data lives on the Mac and that an adapter of this build reads and changes with the app closed.
    /// System Settings goes to the `system` adapter, which has only a few of its settings: the advice says how to
    /// reach the interface when none of its verbs does the task.
    public static let standard = RouteCatalogue([
        "com.apple.iCal"              : "calendar",
        "com.apple.reminders"         : "reminders",
        "com.apple.Notes"             : "notes",
        "com.apple.finder"            : "files",
        "com.apple.systempreferences" : "system",
        "com.apple.mail"              : "mail",
    ])
}
