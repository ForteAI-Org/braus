/// SharedRoutes is the routing advice the `TaskRouter` gives and `open_session` describes, kept in one place so the
/// model reads one rule wherever it reads it.
public enum SharedRoutes {

    /// Rule 1, what counts as naming an app: only "the X app" or the app's brand. A kind of thing is not a
    /// name, so the default route applies.
    public static let namedApp = "The person named an app only when they said \"the X app\" or its brand "
        + "(\"Apple Maps\", \"Mappe di Apple\"). A kind of thing (\"maps\", \"mappe\", \"weather\", "
        + "\"translator\", \"calendar\", \"with Maps\") is not a name: leave named false and use the route given."

    /// The tail of a redirect: when the app itself may still be opened.
    public static func openOnlyIfNamed(_ app: String) -> String {
        "Open \(app) only if the person asked for the app itself (\"the \(app) app\" or its brand); a kind of "
            + "thing is not a name."
    }
}
