import LocalMCP

/// AdapterApproving asks the person whether one irreversible verb call may run (a mail sent, an event deleted), once
/// per call. The app shows the request; a composition without a person (the command line, tests) passes none, and
/// every irreversible verb is refused there.
public protocol AdapterApproving: Sendable {

    /// True only when the person allowed this call. False when they refused it, did not answer in time, or the waiting
    /// task was cancelled: the call is then refused and nothing is done.
    func approve(_ consent: AdapterConsent) async -> Bool
}

/// AdapterConsent is one irreversible verb call as the person reads it before allowing it: the adapter, the app it
/// acts on, the verb, and the arguments that say what it would do (`AppAdapting.consentArguments`). Everything in it
/// was chosen by the model: it is shown, never followed.
public struct AdapterConsent: Sendable, Equatable {

    /// The most lines of a text the person reads.
    public static let excerptLines  = 3
    /// The most characters of a text the person reads.
    public static let excerptLength = 300

    public let adapter  : String
    public let app      : String
    public let verb     : AdapterVerb.Name
    public let arguments: [String: JSONValue]

    public init(
        adapter  : String,
        app      : String,
        verb     : AdapterVerb.Name,
        arguments: [String: JSONValue]
    ) {
        self.adapter   = adapter
        self.app       = app
        self.verb      = verb
        self.arguments = arguments
    }

    /// The arguments as given, each text cut to its first lines (`excerpt`).
    public static func arguments(_ arguments: JSONValue) -> [String: JSONValue] {
        (arguments.object ?? [:]).mapValues { value in value.string.map { .string(excerpt($0)) } ?? value }
    }

    /// A text's first `excerptLines` lines, at most `excerptLength` characters, ending in "…" when cut.
    public static func excerpt(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept  = lines.prefix(excerptLines).joined(separator: "\n")
        guard kept.count > excerptLength || lines.count > excerptLines else { return kept }
        return String(kept.prefix(excerptLength)) + "…"
    }
}
