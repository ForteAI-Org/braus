import EngineCore
import Foundation
import LocalMCP

/// AppAdapters is the set of adapters the tools reach, and the one guarded path to them: it finds the
/// adapter an app name stands for, checks a verb's arguments against its schema, applies the
/// destructive policy and the adapter's availability, and only then runs the verb.
///
/// It holds no state between calls. Adding an adapter is one line in `standard`.
public struct AppAdapters: Sendable {

    public let adapters: [any AppAdapting]
    /// Whether `irreversible` verbs may run: the engine's `allowsDestructive`.
    public let allowsIrreversible: Bool

    public init(_ adapters: [any AppAdapting], allowsIrreversible: Bool = false) {
        self.adapters           = adapters
        self.allowsIrreversible = allowsIrreversible
    }

    /// The adapters of this build on the Mac's own transports.
    public static func standard(allowsIrreversible: Bool = false) -> AppAdapters {
        let store = EventKitStore()
        return AppAdapters([
            SystemAdapter(transport: MacSystemTransport()),
            CalendarAdapter(store: store),
            RemindersAdapter(store: store),
            FilesAdapter(),
            ContactsAdapter(store: MacContactsStore()),
            MailAdapter(transport: MacMailTransport()),
            MessagesAdapter(transport: MacMessagesTransport()),
            NotesAdapter(transport: MacNotesTransport()),
        ], allowsIrreversible: allowsIrreversible)
    }

    /// The adapter an app stands for: its adapter name, one of its app names or one of its bundle
    /// ids, compared without case. Nil when no adapter covers the app.
    public func adapter(for app: String) -> (any AppAdapting)? {
        let wanted = app.trimmingCharacters(in: .whitespaces).lowercased()
        return adapters.first { adapter in
            adapter.name == wanted
                || adapter.appNames.contains { $0.lowercased() == wanted }
                || adapter.bundleIDs.contains { $0.lowercased() == wanted }
        }
    }

    /// The adapter's availability and its verbs matching `query` (all of them without one).
    public func capabilities(of app: String, query: String?) async -> JSONValue {
        guard let adapter = adapter(for: app) else { return missing(app) }
        let query = query?.trimmingCharacters(in: .whitespaces)
        let verbs = adapter.verbs.filter { query?.isEmpty != false || $0.matches(query ?? "") }
        return .object([
            "adapter"     : .string(adapter.name),
            "apps"        : .array(adapter.appNames.map { .string($0) }),
            "availability": await adapter.availability().json,
            "verbs"       : .array(verbs.map { $0.json(adapter: adapter.name) }),
        ])
    }

    /// Every adapter with its availability and verb names.
    public func listing() async -> [(adapter: any AppAdapting, availability: AdapterAvailability)] {
        var listed: [(adapter: any AppAdapting, availability: AdapterAvailability)] = []
        for adapter in adapters { listed.append((adapter, await adapter.availability())) }
        return listed
    }

    /// Asks every adapter (or the one `app` names) for its permission, prompting where the person
    /// has not answered yet, one adapter after the other. Only on the person's request.
    public func requestPermissions(for app: String? = nil) async -> [(adapter: any AppAdapting, availability: AdapterAvailability)] {
        let chosen = app.map { name in adapter(for: name).map { [$0] } ?? [] } ?? adapters
        var asked: [(adapter: any AppAdapting, availability: AdapterAvailability)] = []
        for adapter in chosen { asked.append((adapter, await adapter.requestPermission())) }
        return asked
    }

    /// The verb a call names, resolved on its adapter, with the arguments checked. Throws
    /// `AdapterFailure` for a call no adapter could run as written; nothing has been done then.
    public func resolve(app: String, verb: String, arguments: JSONValue)
        throws -> (adapter: any AppAdapting, verb: AdapterVerb) {
        guard let adapter = adapter(for: app) else {
            throw AdapterFailure("No adapter for \(app). Known: \(adapters.map(\.name).joined(separator: ", ")).")
        }
        let name = verb.hasPrefix("\(adapter.name).") ? String(verb.dropFirst(adapter.name.count + 1)) : verb
        guard let found = adapter.verbs.first(where: { $0.name == name }) else {
            throw AdapterFailure("\(adapter.name) has no verb \(verb). Use app_capabilities to list its verbs.")
        }
        guard let values = arguments == .null ? [:] : arguments.object else {
            throw AdapterFailure("arguments must be an object.")
        }
        let known = Dictionary(uniqueKeysWithValues: found.parameters.map { ($0.name, $0) })
        if let unknown = values.keys.sorted().first(where: { known[$0] == nil }) {
            throw AdapterFailure("\(found.name) takes no argument \(unknown).")
        }
        for parameter in found.parameters {
            guard let value = values[parameter.name], value != .null else {
                if parameter.isRequired { throw AdapterFailure("\(found.name) needs \(parameter.name).") }
                continue
            }
            if let problem = parameter.problem(with: value) { throw AdapterFailure(problem + ".") }
        }
        return (adapter, found)
    }

    /// Runs one verb through the guards: the arguments, the destructive policy, the availability.
    /// A refused call has done nothing.
    ///
    /// It runs off the caller's actor: a verb may block its thread on a script, a contacts fetch, a
    /// database read or a process, and a caller on the main actor keeps the interface answering.
    @concurrent
    public func call(app: String, verb: String, arguments: JSONValue) async throws -> AdapterOutcome {
        let (adapter, found) = try resolve(app: app, verb: verb, arguments: arguments)
        // An irreversible verb runs only with the person's consent and its read-back contract (`IrreversiblePolicy`).
        if found.safety == .irreversible {
            let readBack: IrreversiblePolicy.ReadBack = found.confirmation == .readBack ? .confirms : .cannotConfirm
            switch IrreversiblePolicy.decision(allowed: allowsIrreversible, readBack: readBack) {
                case .allowed:
                    break
                case .needsConsent:
                    return .refused("\(adapter.name).\(found.name) cannot be undone and destructive actions are off "
                                    + "here. Ask the person, who can allow it.")
                case .cannotReadBack:
                    return .refused(IrreversiblePolicy.readBackRefusal("\(adapter.name).\(found.name)"))
            }
        }
        switch await adapter.availability() {
            case .ready, .unknown:
                // An unknown grant is checked by the verb itself, before any event reaches the app.
                let outcome = try await adapter.call(found.name, arguments == .null ? .object([:]) : arguments)
                return Self.checked(outcome, of: found, in: adapter.name)
            case .needsPermission(let reason), .unavailable(let reason):
                return .refused(reason)
        }
    }

    /// An irreversible verb's confirmed answer, checked against its contract: one its read-back did not give is not a
    /// confirmation, so it is answered as a change that may have happened.
    static func checked(_ outcome: AdapterOutcome, of verb: AdapterVerb, in adapter: String) -> AdapterOutcome {
        guard verb.safety == .irreversible, outcome.kind == .foundActed, !outcome.confirmedByReadBack else {
            return outcome
        }
        return AdapterOutcome(.actedUnverified, "\(adapter).\(verb.name) answered done without reading its change "
                              + "back: it may have happened. Read it back before doing it again.",
                              result: outcome.result)
    }

    private func missing(_ app: String) -> JSONValue {
        .object([
            "adapter": .null,
            "message": .string("No adapter for \(app): use open_session to drive it through its interface. "
                               + "Adapters: \(adapters.map(\.name).joined(separator: ", ")).")
        ])
    }
}
