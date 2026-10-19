import AppKit
import Carbon
import Foundation

/// AutomationPermissionNeeded is an app Braus may not send Apple events to yet; it never triggers the
/// consent prompt. Where it came from decides what it proves (A02): asked before the script ran, no
/// event reached the app, and the adapter answers a refusal; raised while the script ran, it may
/// follow events the script already sent, and a change it was making may have happened.
public struct AutomationPermissionNeeded: Error, Sendable, Equatable {
    public let reason: String
    /// Whether it was answered before any Apple event went to the app: only then is nothing known to
    /// have been done. False unless the one who raises it knows, as the runner's check before the
    /// script does.
    public let beforeAnyEvent: Bool
    /// Whether the Mac did not answer for the grant, as opposed to refusing it: nothing says Braus may
    /// not control the app, and nothing says it may (A01).
    public let isGrantUnknown: Bool

    public init(_ reason: String, beforeAnyEvent: Bool = false, isGrantUnknown: Bool = false) {
        self.reason         = reason
        self.beforeAnyEvent = beforeAnyEvent
        self.isGrantUnknown = isGrantUnknown
    }
}

/// ScriptArgument is one parameter of a fixed script's handler, passed as an Apple event parameter,
/// never spliced into the script's text.
enum ScriptArgument: Sendable {
    case text(String)
    case flag(Bool)
    case integer(Int)
    case date(Date)

    var descriptor: NSAppleEventDescriptor {
        switch self {
            case .text(let text)      : NSAppleEventDescriptor(string: text)
            case .flag(let flag)      : NSAppleEventDescriptor(boolean: flag)
            case .integer(let integer): NSAppleEventDescriptor(int32: Int32(clamping: integer))
            case .date(let date)      : NSAppleEventDescriptor(date: date)
        }
    }
}

/// ScriptValue is what a handler answered, read out of its Apple event descriptor.
indirect enum ScriptValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case date(Date)
    case list([ScriptValue])
    case missing

    var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    var list: [ScriptValue] {
        if case .list(let items) = self { return items }
        return []
    }

    var flag: Bool? {
        if case .flag(let flag) = self { return flag }
        return nil
    }

    var date: Date? {
        if case .date(let date) = self { return date }
        return nil
    }

    init(_ descriptor: NSAppleEventDescriptor) {
        switch descriptor.descriptorType {
            case typeAEList:
                self = .list(descriptor.numberOfItems == 0 ? [] : (1...descriptor.numberOfItems).map { index in
                    descriptor.atIndex(index).map(ScriptValue.init) ?? .missing
                })
            case typeTrue, typeFalse, typeBoolean:
                self = .flag(descriptor.booleanValue)
            case typeSInt16, typeSInt32, typeSInt64, typeUInt32:
                self = .number(Double(descriptor.int32Value))
            case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint:
                self = .number(descriptor.doubleValue)
            case typeLongDateTime:
                self = descriptor.dateValue.map(ScriptValue.date) ?? .missing
            case typeType where descriptor.typeCodeValue == OSType(cMissingValue), typeNull:
                self = .missing
            default:
                self = descriptor.stringValue.map(ScriptValue.text) ?? .missing
        }
    }
}

/// AppleScriptRunner runs one handler of a fixed script on an app with a dictionary (Mail, Messages),
/// with its arguments as Apple event parameters. It starts the app hidden when it is not running,
/// checks without asking that Braus may control it, and only then sends the script.
///
/// NSAppleScript is not thread-safe, so every run happens on the main actor.
enum AppleScriptRunner {

    /// The app's availability without prompting and without launching it: installed, and the grant as
    /// the Mac answers it. Ready only when the Mac says events are allowed; an app not running cannot
    /// answer, so its grant is unknown until a verb starts it and checks again (A01).
    static func availability(bundleID: String, app: String) -> AdapterAvailability {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            return .unavailable("\(app) is not installed on this Mac.")
        }
        switch grant(bundleID: bundleID) {
            case .allowed:
                return .ready
            case .refused:
                return .needsPermission(automationNeeded(app).reason)
            case .notAnswerable:
                return .unknown("\(app) is not running, so whether Braus may control it is not known yet; a verb starts "
                                + "it hidden and checks before sending anything.")
        }
    }

    /// Starts the app hidden and asks the person, with the system's prompt when they have not
    /// answered yet, whether Braus may control it. Only on the person's request.
    @MainActor
    static func requestPermission(bundleID: String, app: String) async -> AdapterAvailability {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            return .unavailable("\(app) is not installed on this Mac.")
        }
        do { try await launchHidden(bundleID: bundleID, app: app) } catch { return .unavailable("\(error)") }
        // The prompt blocks the calling thread until the person answers, so it waits off the main actor.
        let status = await Task.detached { () -> OSStatus in
            var target = AEAddressDesc()
            let bytes = Array(bundleID.utf8)
            AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target)
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
        }.value
        return status == noErr ? .ready : .needsPermission(automationNeeded(app).reason)
    }

    /// Runs `handler` of `source` with `arguments` on the app. Throws `AutomationPermissionNeeded`
    /// when the Mac would ask the person first: before the script runs (`beforeAnyEvent`), or from the
    /// script's own events, which may follow others it sent. Throws `AdapterFailure` when the app or
    /// the script fails.
    @MainActor
    static func run(_ source: String, handler: String, _ arguments: [ScriptArgument],
                    bundleID: String, app: String) async throws -> ScriptValue {
        try await launchHidden(bundleID: bundleID, app: app)
        // Asked before the script runs: no event has reached the app.
        if case .failure(let needed) = dispatch(for: grant(bundleID: bundleID), app: app) { throw needed }
        guard let script = NSAppleScript(source: source) else { throw AdapterFailure("The \(app) script did not compile.") }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                           eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: .null(),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() { parameters.insert(argument.descriptor, at: index + 1) }
        event.setParam(parameters, forKeyword: keyDirectObject)
        var error: NSDictionary?
        let answer = script.executeAppleEvent(event, error: &error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == Int(errAEEventNotPermitted) || number == Int(errAEEventWouldRequireUserConsent) {
                // The script ran: events it sent before this one may have had their effect.
                throw automationNeeded(app, beforeAnyEvent: false)
            }
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
            throw AdapterFailure("\(app) refused the script (\(number)): \(message)")
        }
        return ScriptValue(answer)
    }

    /// What the Mac answers, without prompting, to whether Braus may send the app Apple events.
    enum Grant: Equatable {
        case allowed
        case refused
        /// The app is not running, or the Mac gave another answer: nothing is known.
        case notAnswerable
    }

    static func grant(bundleID: String) -> Grant {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target)
        defer { AEDisposeDesc(&target) }
        return grant(status: AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false))
    }

    /// The grant an answer of `AEDeterminePermissionToAutomateTarget` states: allowed only for `noErr`.
    static func grant(status: OSStatus) -> Grant {
        switch Int(status) {
            case Int(noErr):
                .allowed
            case Int(errAEEventWouldRequireUserConsent), Int(errAEEventNotPermitted):
                .refused
            default:
                .notAnswerable
        }
    }

    /// Whether a script may go to the app, by the grant the Mac answers right before it, without prompting: only an
    /// allowed grant lets it go. A refused one, and one the Mac does not answer (an app still starting), stop it
    /// before any event, each saying which (A01).
    static func dispatch(for grant: Grant, app: String) -> Result<Void, AutomationPermissionNeeded> {
        switch grant {
            case .allowed:
                .success(())
            case .refused:
                .failure(automationNeeded(app, beforeAnyEvent: true))
            case .notAnswerable:
                .failure(AutomationPermissionNeeded(
                    "Whether Braus may control \(app) is not known: the Mac did not answer for it (\(app) may still "
                        + "be starting). Nothing was sent; try again once it runs.",
                    beforeAnyEvent: true, isGrantUnknown: true))
        }
    }

    private static func automationNeeded(_ app: String, beforeAnyEvent: Bool = false) -> AutomationPermissionNeeded {
        AutomationPermissionNeeded("Braus may not control \(app) yet. The person allows it in System Settings > "
                                   + "Privacy & Security > Automation, for the app Braus runs in.",
                                   beforeAnyEvent: beforeAnyEvent)
    }

    /// Starts the app hidden and not activated when it is not running, so the script never brings it
    /// in front of the person's work.
    @MainActor
    private static func launchHidden(bundleID: String, app: String) async throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw AdapterFailure("\(app) is not installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates          = false
        configuration.hides              = true
        configuration.addsToRecentItems  = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
