import EngineCore
import LocalMCP

/// AppAdapting is one app's (or one family's) API rung: the verbs Braus can run on it through a
/// public interface (EventKit, CoreAudio, FileManager, a fixed AppleScript), with the app behind or
/// not running at all, and without a seat.
///
/// An adapter never prompts for a permission, never runs a script the agent wrote, and ships a verb
/// only with the read-back that confirms its effect: `call` reads the effect back before it answers.
public protocol AppAdapting: Sendable {

    /// The adapter's short name, the first word of its verbs: `system`, `calendar`, `files`.
    var name: String { get }

    /// The apps it stands for, by the names a person or an agent uses for them.
    var appNames: [String] { get }

    /// The bundle identifiers of those apps, for the memory and for routing by bundle id.
    var bundleIDs: Set<String> { get }

    /// The verbs it offers; fixed at build time, so listing them costs no discovery.
    var verbs: [AdapterVerb] { get }

    /// Whether it can run now: transport alive, permission granted. Never prompts.
    func availability() async -> AdapterAvailability

    /// Asks the system for the permission the adapter needs, showing its prompt when the person has
    /// not answered yet, and answers the availability after. The one path that may prompt: it runs only
    /// when the person asks for it (`braus adapters grant`, a host's menu), never from a tool call.
    func requestPermission() async -> AdapterAvailability

    /// Runs one verb, whose arguments `AppAdapters` already checked against its schema, and reads its
    /// effect back. Throws `AdapterFailure` when the transport fails; a refusal or an effect the
    /// read-back does not confirm is an outcome, not an error.
    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome
    /// What the person reads about an irreversible call of `verb` before allowing it, by argument. By
    /// default the arguments as given, each text cut to its first lines; an adapter whose arguments do
    /// not say what would change (an id) reads it first. Never changes anything.
    func consentArguments(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async -> [String: JSONValue]
}

extension AppAdapting {
    /// An adapter that needs no permission, or none the system can ask for, answers its availability.
    public func requestPermission() async -> AdapterAvailability {
        await availability()
    }

    public func consentArguments(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async -> [String: JSONValue] {
        AdapterConsent.arguments(arguments)
    }
}

/// AdapterAvailability is whether an adapter can run now, with the sentence an agent passes on
/// when it cannot.
public enum AdapterAvailability: Sendable, Equatable {
    case ready
    /// Braus lacks a permission; the text says which and where the person grants it.
    case needsPermission(String)
    /// The transport is missing on this Mac (no Wi-Fi interface, the app not installed).
    case unavailable(String)
    /// Whether Braus may use it cannot be told without starting the app or asking the person (an app
    /// not running cannot answer); a verb starts it hidden and checks before any event (A01).
    case unknown(String)

    public var isReady: Bool { self == .ready }

    /// The availability as the tools report it.
    public var json: JSONValue {
        switch self {
            case .ready                      : .object(["state": .string("ready")])
            case .needsPermission(let reason): .object(["state": .string("needs_permission"), "reason": .string(reason)])
            case .unavailable(let reason)    : .object(["state": .string("unavailable"), "reason": .string(reason)])
            case .unknown(let reason)        : .object(["state": .string("unknown"), "reason": .string(reason)])
        }
    }
}

/// AdapterOutcome is what one verb did, in the engine's outcome words, with a small JSON result.
///
/// `foundActed` means the read-back confirmed the effect (or a read answered); `actedUnverified`
/// means the transport accepted the change and the read-back did not see it; `honestMiss` means the
/// thing the verb names does not exist; `refused` means nothing was done, and the message says why.
public struct AdapterOutcome: Sendable, Equatable {
    public let kind   : ActOutcomeKind
    public let message: String
    public let result : JSONValue
    /// Whether a confirmed answer came from reading the change back (`afterChange`): the proof an irreversible verb's
    /// confirmation needs (`AdapterVerb.Confirmation`).
    public let confirmedByReadBack: Bool

    public init(_ kind: ActOutcomeKind, _ message: String, result: JSONValue = .null) {
        self.init(kind, message, result: result, confirmedByReadBack: false)
    }

    private init(_ kind: ActOutcomeKind, _ message: String, result: JSONValue, confirmedByReadBack: Bool) {
        self.kind                = kind
        self.message             = message
        self.result              = result
        self.confirmedByReadBack = confirmedByReadBack
    }

    public static func confirmed(_ message: String, _ result: JSONValue = .null) -> AdapterOutcome {
        AdapterOutcome(.foundActed, message, result: result)
    }

    public static func refused(_ message: String) -> AdapterOutcome {
        AdapterOutcome(.refused, message)
    }

    public static func missing(_ message: String) -> AdapterOutcome {
        AdapterOutcome(.honestMiss, message)
    }

    /// The answer to a change the transport took, or may have taken, when what follows it could not finish: the change
    /// failing midway, its read-back throwing, the permission to read it back withdrawn, the call cancelled. The change
    /// may have happened, so it is never answered as refused or as an error a caller would retry (A02, A08). The
    /// error's own text stays out of the answer, which could repeat what was written.
    public static func mayHaveHappened(_ action: String, because error: any Error, look: String,
                                       result: JSONValue = .null) -> AdapterOutcome {
        let why = switch error {
            case is AutomationPermissionNeeded: "the Mac withdrew the permission to control the app"
            case is CancellationError        : "the call was cancelled"
            default                          : "what followed failed"
        }
        return AdapterOutcome(.actedUnverified, "\(action), but \(why): it may have happened. \(look) before doing it "
                              + "again.", result: result)
    }

    /// Runs `readBack`, what follows a change that went out: an error it throws, a cancellation included, is answered
    /// by `mayHaveHappened`, never thrown. A confirmed answer it gives is marked as confirmed by the read-back.
    public static func afterChange(_ action: String, look: String, result: JSONValue = .null,
                                   _ readBack: () async throws -> AdapterOutcome) async -> AdapterOutcome {
        do {
            let read = try await readBack()
            guard read.kind == .foundActed else { return read }
            return AdapterOutcome(read.kind, read.message, result: read.result, confirmedByReadBack: true)
        } catch {
            return .mayHaveHappened(action, because: error, look: look, result: result)
        }
    }

    public var json: JSONValue {
        .object(["outcome": .string(kind.rawValue), "message": .string(message), "result": result])
    }

    /// The check of this answer by the adapters' oracle (P2-03), distinct from whether the verb was accepted: a read
    /// that answered passes `adapter_read`; a change passes `adapter_effect` only when its read-back gave the
    /// confirmation (`confirmedByReadBack`), and is unknown otherwise; a change that may have happened is unknown with
    /// its delivery uncertain; a verb that did nothing (refused, missing, ambiguous, a dry run) sent nothing and fails
    /// its condition; one with nothing left to do found the state already there.
    public func check(for verb: AdapterVerb) -> OperationCheck {
        let condition: OperationCheck.Condition = verb.safety == .read ? .adapterRead : .adapterEffect
        func check(_ verdict: OperationCheck.Verdict, _ performed: OperationCheck.Performed,
                   _ limits: [OperationCheck.Limit] = [], as kind: OperationCheck.Condition? = nil) -> OperationCheck {
            OperationCheck(condition: kind ?? condition, method: .adapterReadBack, methodVersion: OperationCheck.adapterVersion,
                           verdict: verdict, limits: limits, performed: performed)
        }
        switch kind {
            case .foundActed:
                if verb.safety == .read || confirmedByReadBack { return check(.passed, .requested) }
                return check(.unknown, .requested, [.readbackUnavailable])
            case .actedNoop:
                return check(.passed, .none, as: .requestedStateAlreadyPresent)
            case .actedUnverified:
                return check(.unknown, .uncertain, [.deliveryUncertain, .readbackUnavailable])
            case .honestMiss, .refused, .ambiguous, .dryRun:
                return check(.failed, .none)
        }
    }
}

/// AdapterFailure is a transport that failed: the call may or may not have had its effect, so the
/// agent reads the state back with a read verb before anything else.
public struct AdapterFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
