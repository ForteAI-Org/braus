/// SharedRoutes keeps the desktop and browser routing advice in one place.
public enum SharedRoutes {

    /// Rule 1, what counts as naming an app: only "the X app" or the app's brand. A kind of thing is not a
    /// name, so the default route applies (maps go to Google Maps on the web, which needs no login).
    public static let namedApp = "The person named an app only when they said \"the X app\" or its brand "
        + "(\"Apple Maps\", \"Mappe di Apple\"). A kind of thing (\"maps\", \"mappe\", \"weather\", "
        + "\"translator\", \"calendar\", \"with Maps\") is not a name: leave named false and use the route given."

    /// The tail of a redirect: when the app itself may still be opened.
    public static func openOnlyIfNamed(_ app: String) -> String {
        "Open \(app) only if the person asked for the app itself (\"the \(app) app\" or its brand); a kind of "
            + "thing is not a name."
    }

    /// Writing to someone: the channel comes from the memory, per contact.
    public static let messageChannel = "To write to someone, use the channel that worked last time with that "
        + "contact, from the memory; when it is unknown, ask the person once and remember the answer."

    /// WhatsApp, once it is the channel: a send ends where Braus reads it back, so on the web.
    public static let whatsApp = "For WhatsApp, send through WhatsApp Web (web:web.whatsapp.com): a send must end "
        + "where Braus can read it back. The WhatsApp app is for reading."

    /// Mail without the web engine: the account still comes first.
    public static let mailAccountOnly = "Ask the person which mail account unless the memory knows."

    /// Mail: the account's web mail.
    public static let mailAccount = "Mail goes through the account's web mail: Gmail at web:mail.google.com, "
        + "Outlook at web:outlook.live.com. Ask the person which account unless the memory knows."

    /// How Braus's own browser engine is reached, as the instructions, `open_session` and the advice name it.
    public static let browserEngine = "open_session with web:<host> or the page's URL"

    /// How the desktop is reached, as advice names it.
    public static let desktop = "the desktop (open_session: the MacDriver with the app behind, else the seat)"
}
