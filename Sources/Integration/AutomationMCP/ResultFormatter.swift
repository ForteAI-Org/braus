import AppAdapters
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Switches
#if BRAUS_PHASES
import PhaseSignposts
#endif

/// ResultFormatter renders tool answers and transcripts using the producer and scene state it borrows.
final class ResultFormatter {
    nonisolated enum OutcomeArm: String, Sendable { case v1, v2 }
    static var usesOutcomeV2: Bool { SwitchBoard.current.arm("outcome", default: OutcomeArm.v1) == .v2 }

    struct RefusalContext {
        let sessionID: UUID
        let windowNumber: Int
        let tool: String
        let arguments: JSONValue
    }

    private struct Refusal: Equatable {
        let tool: String
        let arguments: JSONValue
        let cause: String?
    }

    /// Keeps only content facts; capture tokens and learned annotations cannot clear a refusal.
    private struct SceneContent: Equatable {
        let bundleID: String
        let windowTitle: String
        let viewportPixelSize: ViewportPixelSize
        let sections: [SceneSection]
        let commands: [String]
        let outOfViewFields: [OutOfViewField]
        let elements: [SceneElement]

        init(scene: SceneSnapshot) {
            bundleID = scene.bundleID
            windowTitle = scene.windowTitle
            viewportPixelSize = scene.viewportPixelSize
            sections = scene.sections
            commands = scene.commands.sorted()
            outOfViewFields = scene.outOfViewFields
            elements = Self.elements(scene)
        }

        private static func elements(_ scene: SceneSnapshot) -> [SceneElement] {
            scene.elements.map {
                SceneElement(id: $0.id, kind: .control, label: $0.label, bounds: $0.bounds,
                             role: $0.role, state: $0.state, value: $0.value, isEnabled: $0.isEnabled,
                             container: $0.container, section: $0.section)
            }.sorted { $0.id < $1.id }
        }
    }

    private var refusalSessionID: UUID?
    private var contents: [Int: SceneContent] = [:]
    private var refusals: [Int: Refusal] = [:]

    func resetRefusals() {
        contents.removeAll()
        refusals.removeAll()
        refusalSessionID = nil
    }

    private func useSession(_ id: UUID) {
        if refusalSessionID != id {
            resetRefusals()
            refusalSessionID = id
        }
    }

    func noteScene(_ scene: SceneSnapshot, sessionID: UUID, windowNumber: Int) {
        guard Self.usesOutcomeV2 else { return }
        useSession(sessionID)
        let content = SceneContent(scene: scene)
        if let prior = contents[windowNumber], prior != content { refusals[windowNumber] = nil }
        contents[windowNumber] = content
    }

    private static func gestureArguments(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value else { return value }
        for key in ["token", "correlation_id", "correlationID", "session", "operation"] { fields.removeValue(forKey: key) }
        return .object(fields)
    }

    private let session: any AutomationSessionOperating
    private unowned let secrets: ProducerSecrets
    private unowned let sceneText: SceneTextPolicy
    var record: ((String) throws -> Void)?

    init(
        session: any AutomationSessionOperating,
        secrets: ProducerSecrets,
        sceneText: SceneTextPolicy
    ) {
        self.session = session
        self.secrets = secrets
        self.sceneText = sceneText
    }

    /// The answer of a call, with the memory's notice when part of it was not recorded, as the model reads it.
    func finish(_ name: String, _ value: JSONValue, notice: String?, output: CallOutput) throws -> JSONValue {
        #if BRAUS_PHASES
        let rendering = PhaseInterval.begin("render.result")
        defer { rendering.end() }
        #endif
        var value = value
        if Self.usesOutcomeV2, case .object(var fields) = value,
           let status = fields["status"]?.string, let kind = ActOutcomeKind(rawValue: status) {
            let outcome = Outcome.converting(kind, check: output.lastCheck, notSent: nil,
                                            noop: nil, sceneAttached: fields["observation"] != nil)
            fields.removeValue(forKey: "status")
            fields.removeValue(forKey: "evidence")
            fields["gesture"] = .string(outcome.gesture.rawValue)
            fields["effect"] = .string(outcome.effect.text)
            fields["recovery"] = .string(outcome.recovery.text)
            fields["_outcome_message"] = .string(OutcomeText.message(
                OutcomeKey(outcome: outcome, verb: name), label: nil
            ))
            value = .object(fields)
        }
        var answered = Self.noted(Self.noted(value, session.seatNotice), session.browserNotice, as: "browser")
        if let notice, case .object(var object) = answered {
            object["memory"] = .string(notice)
            answered = .object(object)
        }
        let shown = secrets.shownMinimization
        if !shown.knowsNoText { answered = ProducerSecrets.minimized(answered, by: shown) }
        let outcomeText = Self.usesOutcomeV2 ? try Self.outcomeText(answered) : nil
        var transcribed = answered
        if case .object(var object) = answered, !output.transcriptOmits.isEmpty || !output.contentTexts.isEmpty {
            object["result"] = object["result"].map { Self.withholding(Set(output.transcriptOmits), in: $0) }
            let minimization = ValueMinimization(secrets: output.contentTexts)
            transcribed = Self.mappingTexts(.object(object)) { minimization.minimize(text: $0).0 }
        }
        if Self.usesOutcomeV2 { transcribed = Self.transcriptOutcome(transcribed) }
        try transcribe("← \(name)", transcribed)
        if let outcomeText { return MCPRouter.textResult(outcomeText + (notice.map { "\nmemory: \($0)" } ?? "")) }
        if let modelText = output.modelText {
            return MCPRouter.textResult(shown.minimize(text: modelText).0 + (notice.map { "\nmemory: \($0)" } ?? ""))
                .adding("structuredContent", answered)
        }
        return MCPRouter.toolResult(answered)
    }

    /// Hands a line to the transcript with every value the memory withholds withheld here too: the
    /// producer's secrets, the current call's withheld texts (`CallScope`) and the credential shapes, so no log of
    /// the tools keeps what the archive may not. A JSON value is minimized value by value before it is encoded, so
    /// a text JSON escapes (a quote, a backslash, a line break) is found as written.
    func transcribe(_ line: String, _ value: JSONValue? = nil) throws {
        guard let record else { return }
        let minimization = secrets.recordMinimization
        var text = minimization.minimize(text: line).0
        if let value {
            text += " " + String(decoding: try JSONEncoder().encode(ProducerSecrets.minimized(value, by: minimization)), as: UTF8.self)
        }
        try record(text)
    }

    /// A verb's arguments as the memory keeps them: JSON with sorted keys, `{}` when absent.
    static func canonical(_ arguments: JSONValue) throws -> String {
        let value = arguments == .null ? JSONValue.object([:]) : arguments
        guard value.object != nil else { throw AutomationFailure("arguments must be an object.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A call's arguments as its record and its transcript keep them. For `app_call`, the values of the verb's content
    /// parameters (`AdapterParameter.isContent`, a text written, appended or found) become the marker, and every text
    /// of its arguments does when the verb cannot be resolved, since none was told apart. Other calls are kept whole.
    /// The answer's record is searched for those values as well (`content(of:arguments:outcome:)`), since a message may
    /// repeat them (the title of a note it created); an adapter's error repeats none.
    private func withheldContent(_ name: String, _ arguments: JSONValue, adapters: AppAdapters?) -> JSONValue {
        guard name == "app_call", case .object(var call) = arguments, let values = call["arguments"],
              values != .null else { return arguments }
        let verb = adapters.flatMap { adapters -> AdapterVerb? in
            guard let app = arguments["app"].string, let verb = arguments["verb"].string else { return nil }
            return try? adapters.resolve(app: app, verb: verb, arguments: values).verb
        }
        guard let verb, case .object(var fields) = values else {
            call["arguments"] = Self.withholdingTexts(values)
            return .object(call)
        }
        for parameter in verb.parameters where (parameter.isContent || parameter.confidentiality != .ordinary) && fields[parameter.name] != nil {
            fields[parameter.name] = .string(ValueMinimization.marker)
        }
        call["arguments"] = .object(fields)
        return .object(call)
    }

    /// `value` with every text in it, however nested, replaced by the marker.
    private static func withholdingTexts(_ value: JSONValue) -> JSONValue {
        mappingTexts(value) { _ in ValueMinimization.marker }
    }

    /// `value` with every text in it, however nested, replaced by `transform` of it.
    private static func mappingTexts(_ value: JSONValue, _ transform: (String) -> String) -> JSONValue {
        switch value {
            case .string(let text)  : .string(transform(text))
            case .array(let items)  : .array(items.map { mappingTexts($0, transform) })
            case .object(let fields): .object(fields.mapValues { mappingTexts($0, transform) })
            default                 : value
        }
    }

    /// `value` with the value of every key in `keys`, at any depth, withheld as `withholdingTexts` does.
    private static func withholding(_ keys: Set<String>, in value: JSONValue) -> JSONValue {
        switch value {
            case .array(let items)  : .array(items.map { withholding(keys, in: $0) })
            case .object(let fields):
                .object(fields.reduce(into: [:]) { kept, field in
                    kept[field.key] = keys.contains(field.key) ? withholdingTexts(field.value)
                                                               : withholding(keys, in: field.value)
                })
            default                 : value
        }
    }

    /// Every text in `value`, however nested; with `keys`, only those under one of them, at any depth.
    private static func texts(in value: JSONValue, under keys: Set<String>?) -> [String] {
        switch value {
            case .string(let text)  : keys == nil ? [text] : []
            case .array(let items)  : items.flatMap { texts(in: $0, under: keys) }
            case .object(let fields):
                fields.flatMap { key, field in texts(in: field, under: keys?.contains(key) == true ? nil : keys) }
            default                 : []
        }
    }

    /// The content texts of an adapter call (its content parameters, every text of its arguments when the verb is not
    /// known, and its content results), withheld wherever a record repeats them, in a message that names a title too.
    static func content(of verb: AdapterVerb?, arguments: JSONValue, outcome: AdapterOutcome) -> [String] {
        guard let verb else { return texts(in: arguments) }
        let given = verb.parameters.filter(\.isContent).flatMap { texts(in: arguments[$0.name]) }
        return given + texts(in: outcome.result, under: Set(verb.contentResults))
    }

    /// `value` with the seat's note about windows its scene does not show, when it carries a scene.
    private static func noted(
        _ value : JSONValue,
        _ notice: String?,
        as key  : String = "notice"
    ) -> JSONValue {
        guard let notice, case .object(var object) = value,
              object["scene"] != nil || object["changes"] != nil || object["observation"] != nil
        else { return value }
        object[key] = .string(notice)
        return .object(object)
    }

    /// A collection as the model reads it: the posts in the order first found, each with what the page showed of it
    /// (a text Braus kept only the start of says its full length), then how many, against what, why it stopped,
    /// and that the page was scrolled.
    static func collection(_ collected: PostCollection) -> JSONValue {
        func put(_ object: inout [String: JSONValue], _ key: String, _ text: String?) {
            if let text, !text.isEmpty { object[key] = .string(text) }
        }
        let posts: [JSONValue] = collected.posts.map { post in
            var object: [String: JSONValue] = ["id": .string(post.identity), "text": .string(post.text)]
            put(&object, "author", post.author)
            put(&object, "handle", post.handle)
            put(&object, "url", post.url)
            put(&object, "time", post.time)
            put(&object, "context", post.context)
            if post.truncated {
                object["truncated"] = .bool(true)
                object["length"] = .number(Double(post.textLength))
            }
            if post.shortenedBySite { object["shortened_by_site"] = .bool(true) }
            if post.fieldsClipped { object["fields_clipped"] = .bool(true) }
            if let quote = post.quote {
                var quoted: [String: JSONValue] = ["text": .string(quote.text)]
                if quote.truncated {
                    quoted["truncated"] = .bool(true)
                    quoted["length"] = .number(Double(quote.textLength))
                }
                put(&quoted, "author", quote.author)
                put(&quoted, "handle", quote.handle)
                put(&quoted, "url", quote.url)
                object["quote"] = .object(quoted)
            }
            return .object(object)
        }
        return .object([
            "page": .string(collected.pageURL), "reader": .string(collected.site), "posts": .array(posts),
            "count": .number(Double(collected.posts.count)), "target": .number(Double(collected.target)),
            "partial": .bool(collected.isPartial), "stop": .string(collected.stop.rawValue),
            "reason": .string(collected.reason), "scrolls": .number(Double(collected.scrolls)),
            "next": .string(collected.scrolls > 0 ? "The page was scrolled: observe before acting on it."
                                                  : "The page was not scrolled.")
        ])
    }

    /// The resource kind an adapter's items are, for a call's data context (P2-05); nil for an adapter whose items the
    /// record does not name (files, the system).
    static let adapterItems: [String: String] = [
        "mail": "message", "messages": "message", "notes": "note", "calendar": "event", "reminders": "reminder",
        "contacts": "contact",
    ]

    /// The data an adapter call reached (P2-05): the adapter as the service, its account only as the verb's account
    /// parameter names it (or its default, said as such), and the item it names by `id`, in its arguments or its result.
    static func dataContext(of resolved: (adapter: any AppAdapting, verb: AdapterVerb), arguments: JSONValue,
                            result: JSONValue?) -> CallDataContext {
        let named = resolved.verb.accountParameter.flatMap { arguments[$0].string }.flatMap { $0.isEmpty ? nil : $0 }
        let source: CallDataContext.AccountSource = resolved.verb.accountParameter == nil ? .unknown
            : named == nil ? .default : .argument
        let kind = adapterItems[resolved.adapter.name]
        let item = kind == nil ? nil : arguments["id"].string ?? result?["id"].string
        let context = try? CallDataContext(service: resolved.adapter.name, route: .adapter, account: named,
                                           accountSource: source, resourceKind: item == nil ? nil : kind, resource: item)
        return context ?? (try! CallDataContext(service: resolved.adapter.name, route: .adapter, accountSource: .unknown))
    }

    /// The evidence of a call as the agent reads it (P2-03): whether the route accepted the command, apart from what
    /// its own oracle found of the effect (condition, method and version, verdict, limits, what was performed). Whether
    /// the task's goal was reached is the task's result check, never this. Nil without a check.
    static func evidence(_ check: OperationCheck?, kind: ActOutcomeKind) -> JSONValue? {
        guard let check else { return nil }
        let accepted: String = switch check.performed {
            case .requested, .substitute: "accepted"
            case .none                  : "not_sent"
            case .uncertain             : "uncertain"
        }
        return .object([
            "command": .string(accepted),
            "effect": .object([
                "condition": .string(check.condition.rawValue),
                "method"   : .string(check.method.rawValue),
                "version"  : .string(check.methodVersion),
                "verdict"  : .string(check.verdict.rawValue),
                "limits"   : .array(check.limits.map { .string($0.rawValue) }),
            ]),
            "goal": .string("not judged by a call: the task's result check says it"),
        ])
    }

    func outcome(_ outcome: ActOutcome, refusal: RefusalContext? = nil) async -> JSONValue {
        if let scene = outcome.scene, let id = session.id, let window = session.observedWindowNumber {
            noteScene(scene, sessionID: id, windowNumber: window)
        }
        var values: [String: JSONValue] = [
            "status": .string(outcome.kind.rawValue), "message": .string(outcome.message),
            "session": session.id.map { .string($0.uuidString) } ?? .null
        ]
        if let scene = outcome.scene { values["observation"] = await sceneText.observation(scene, changesOnly: true, nested: true,
                                                                                          session: session, shown: secrets.shownMinimization) }
        if Self.usesOutcomeV2 {
            values.removeValue(forKey: "status")
            var typed = outcome.outcome
            var cause = outcome.cause
            if let refusal {
                useSession(refusal.sessionID)
                if typed.gesture == .notSent {
                    let key = Refusal(tool: refusal.tool, arguments: Self.gestureArguments(refusal.arguments), cause: cause)
                    if typed.recovery != .continue {
                        if refusals[refusal.windowNumber] == key {
                            typed = Outcome(gesture: .notSent, effect: .notApplicable, recovery: .doNotRepeat)
                            cause = "already_refused"
                        }
                        refusals[refusal.windowNumber] = key
                    }
                } else if typed.gesture == .sent {
                    refusals[refusal.windowNumber] = nil
                }
            }
            if cause == nil && typed.gesture == .uncertain { cause = "seat_error" }
            if outcome.noop == .listing && outcome.scene == nil {
                values["observation"] = .string(outcome.message)
            }
            values["gesture"] = .string(typed.gesture.rawValue)
            values["effect"] = .string(typed.effect.text)
            values["recovery"] = .string(typed.recovery.text)
            values["_outcome_message"] = .string(OutcomeText.message(
                OutcomeKey(outcome: typed, verb: refusal?.tool ?? "", cause: cause), label: nil
            ))
            return .object(values)
        }
        // P2-03: what the operation's own oracle found, apart from the command's acceptance and the task's goal.
        if let evidence = Self.evidence(outcome.withStatedCheck.check, kind: outcome.kind) { values["evidence"] = evidence }
        return .object(values)
    }

    /// Renders a typed action, or replaces the action objects of a batch with their rows.
    private static func outcomeText(_ value: JSONValue) throws -> String? {
        if let gesture = value["gesture"].string, let effect = value["effect"].string,
           let recovery = value["recovery"].string {
            var text = "\(gesture) · \(effect) · \(recovery)\n" + (value["_outcome_message"].string ?? "")
            for key in ["observation", "result", "notice", "browser"] where value[key] != .null {
                text += "\n" + String(decoding: try JSONEncoder().encode(value[key]), as: UTF8.self)
            }
            return text
        }
        guard value["steps"].array != nil else { return nil }
        return String(decoding: try JSONEncoder().encode(batchOutcome(value)), as: UTF8.self)
    }

    private static func transcriptOutcome(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items): return .array(items.map(transcriptOutcome))
        case .object(var fields):
            fields.removeValue(forKey: "_outcome_message")
            return .object(fields.mapValues(transcriptOutcome))
        default: return value
        }
    }

    private static func batchOutcome(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items): return .array(items.map(batchOutcome))
        case .object(var fields):
            if fields["status"]?.string == "error" {
                let outcome = Outcome.converting(.actedUnverified, check: .unchecked(performed: .uncertain),
                    notSent: nil, noop: nil, sceneAttached: fields["observation"] != nil)
                fields["outcome"] = .string(outcome.row)
                fields["message"] = .string(OutcomeText.message(
                    OutcomeKey(outcome: outcome, verb: "", cause: "thrown"), label: nil
                ))
                fields.removeValue(forKey: "status")
                fields.removeValue(forKey: "evidence")
            }
            if let gesture = fields["gesture"]?.string, let effect = fields["effect"]?.string,
               let recovery = fields["recovery"]?.string {
                fields["outcome"] = .string("\(gesture) · \(effect) · \(recovery)")
                fields["message"] = fields["_outcome_message"]
                for key in ["gesture", "effect", "recovery", "_outcome_message", "status", "evidence"] {
                    fields.removeValue(forKey: key)
                }
            }
            return .object(fields.mapValues(batchOutcome))
        default: return value
        }
    }

    /// Classifies only a validated call as potentially acting; the answer still owns validation errors.
    func mayAct(
        _ name: String,
        arguments: JSONValue,
        request: AgentCallRequest?,
        definitions: [JSONValue]
    ) -> Bool {
        guard let request, request.tool.requiresConfirmedStart,
              let fields = arguments.object,
              let definition = definitions.first(where: { $0["name"].string == name }) else { return false }
        let schema = definition["inputSchema"]
        let allowed = Set(schema["properties"].object?.keys.map { $0 } ?? [])
        guard Set(fields.keys).isSubset(of: allowed),
              (schema["required"].array ?? []).allSatisfy({ $0.string.map { fields[$0] != nil } == true }) else {
            return false
        }
        if request.tool.takesSession {
            return session.id.map { arguments["session"].string == $0.uuidString } == true
        }
        return true
    }

    /// Answers a non-cancellation failure using only catalogue prose for the model.
    func thrown(_ error: any Error, tool: String, mayHaveActed: Bool) -> JSONValue {
        let outcome = Outcome.converting(mayHaveActed ? .actedUnverified : .refused,
                                        check: mayHaveActed ? .unchecked(performed: .uncertain) : nil,
                                        notSent: nil, noop: nil, sceneAttached: false)
        let text = outcome.row + "\n" + OutcomeText.message(
            OutcomeKey(outcome: outcome, verb: tool, cause: "thrown"), label: nil
        )
        return MCPRouter.textResult(text).adding("isError", .bool(true))
    }

    /// Every text of a JSON value, however nested: what a call the schema will refuse may carry anywhere.
    static func texts(in value: JSONValue) -> [String] {
        switch value {
            case .string(let text)  : return [text]
            case .array(let items)  : return items.flatMap { texts(in: $0) }
            case .object(let fields): return fields.values.flatMap { texts(in: $0) }
            default                 : return []
        }
    }

}

extension JSONValue {

    /// The object with `key` set to `value`; itself when `value` is nil or it is not an object.
    func adding(_ key: String, _ value: JSONValue?) -> JSONValue {
        guard let value, case .object(var fields) = self else { return self }
        fields[key] = value
        return .object(fields)
    }
}
