import AppAdapters
import AppKit
import CryptoKit
import AutomationRuntime
import EngineCore
import Foundation
import os
import LocalMCP
import Memory
import PerceptionCore
#if BRAUS_PHASES
import PhaseSignposts
#endif
import PrivateSymbols
import SeatCore
import TaskRouting

/// CallDispatcher runs a call in its scope and recorder, borrowing state kept alive by the facade.
final class CallDispatcher {
    private let session: any AutomationSessionOperating
    private let channels: AutomationChannels
    var adapters: AppAdapters?
    var router: TaskRouter?
    private unowned let producerSecrets: ProducerSecrets
    private unowned let sceneText: SceneTextPolicy
    private unowned let taskCycle: TaskCycleHandler
    private unowned let formatter: ResultFormatter
    private var output = CallOutput()
    private typealias Step = ToolArguments.Step
    private var producer: CallProducer { taskCycle.producer }

    init(
        session: any AutomationSessionOperating,
        channels: AutomationChannels,
        adapters: AppAdapters?,
        router: TaskRouter?,
        secrets: ProducerSecrets,
        sceneText: SceneTextPolicy,
        taskCycle: TaskCycleHandler,
        formatter: ResultFormatter
    ) {
        self.session = session
        self.channels = channels
        self.adapters = adapters
        self.router = router
        self.producerSecrets = secrets
        self.sceneText = sceneText
        self.taskCycle = taskCycle
        self.formatter = formatter
    }

    /// The channels this instance serves: those composed, `.adapters` while `adapters` is set and `.web` while
    /// `router` is and the web is composed.
    var served: AutomationChannels {
        var served = channels.subtracting([.web, .adapters])
        if adapters != nil { served.insert(.adapters) }
        if router != nil, channels.contains(.web) { served.insert(.web) }
        return served
    }

    var toolDefinitions: [JSONValue] { ToolCatalogue.definitions(for: served) }

    private func finish(
        _ name: String,
        _ value: JSONValue,
        notice: String?
    ) throws -> JSONValue {
        try formatter.finish(
            name,
            value,
            notice: notice,
            output: output
        )
    }

    private func outcome(_ value: ActOutcome) async -> JSONValue { await formatter.outcome(value) }

    private func observation(
        _ scene: SceneSnapshot,
        changesOnly: Bool = false,
        nested: Bool = false
    ) async -> JSONValue {
        await sceneText.observation(
            scene,
            changesOnly: changesOnly,
            nested: nested,
            session: session,
            shown: producerSecrets.shownMinimization
        )
    }

    /// Runs one tool call. Before anything of it is written (its transcript line, its record), the texts it would
    /// type are classified on a fresh perception (`scope(of:_:)`, W1): what the call withholds and the field each
    /// text step is bound to are its `CallScope`, bound from there to its last output, the error it throws included.
    func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let started = ContinuousClock.now
        let log = Logger(subsystem: "dev.forte.Braus", category: "AutomationTools")
        if name == "open_session" { log.info("open_session: tool starting (scope, route and recording)") }
        defer {
            if name == "open_session" {
                let elapsed: Duration = started.duration(to: .now)
                log.info("open_session: tool ended after \(elapsed.description, privacy: .public)")
            }
        }
        #if BRAUS_PHASES
        let tool = PhaseInterval.begin("tool", name)
        defer { tool.end() }
        #endif
        let scope = await scope(of: name, arguments)
        do {
            return try await CallScope.$current.withValue(scope) {
                try await MemoryService.labelled("tool \(name)") { try await toolCall(name, arguments) }
            }
        } catch {
            // The error reaches the model and its log: the producer's secrets and what the call withholds are
            // withheld from it too.
            let shown = ValueMinimization(secrets: producerSecrets.secrets, classified: scope.withheld, scrubsCredentials: false)
            guard !(error is CancellationError), !shown.knowsNoText else { throw error }
            let (kept, reason) = shown.minimize(text: String(describing: error))
            guard reason != nil else { throw error }
            throw AutomationFailure(kept)
        }
    }

    /// What a call withholds and binds before its first write (W1). A `type_text` or `insert_text`, or a batch's
    /// first step when it is one of them, is classified by the session on a fresh perception: an ordinary field's
    /// text is kept and its dispatch bound to that field; a secure field's text is withheld and becomes one of the
    /// producer's secrets; any other is withheld for this call only, as unclassified. A batch's later text steps
    /// come after an earlier step's effect, so they cannot be classified when the batch is planned: their texts are
    /// withheld in the plan. A text whose call names another session, or whose step the call will refuse, is
    /// withheld as unclassified too, since its transcript line comes before the refusal.
    private func scope(of name: String, _ arguments: JSONValue) async -> CallScope {
        var scope = CallScope()
        if name == "app_call" { return contentScope(of: arguments) }
        confidentialScope(of: name, arguments, in: &scope)
        guard ["type_text", "insert_text", "batch"].contains(name) else { return scope }
        let rows = name == "batch" ? (arguments["steps"].array ?? []) : [arguments]
        let current = session.id.map { arguments["session"].string == $0.uuidString } ?? false
        for (position, row) in rows.enumerated() {
            let operation = name == "batch" ? (row["operation"].string ?? "") : name
            guard let step = try? Step(operation, row) else {
                for key in ["text", "expected_value"] {
                    if let text = row[key].string { scope.withhold(text, .unclassifiedTarget) }
                }
                continue
            }
            let texts = step.texts
            guard case .input(let input, let section) = step, !texts.isEmpty else { continue }
            guard position == 0, current else {
                for text in texts { scope.withhold(text, .unclassifiedTarget) }
                continue
            }
            switch await session.classify(input, section: section) {
                case .ordinary(let binding):
                    scope.bindings[position] = binding
                case .secure:
                    for text in texts {
                        scope.withhold(text, .secureField)
                        for form in CallScope.forms(of: text) where !producerSecrets.secrets.contains(form) { producerSecrets.secrets.append(form) }
                    }
                case .unclassified:
                    for text in texts { scope.withhold(text, .unclassifiedTarget) }
            }
        }
        return scope
    }

    /// What an `app_call` withholds (P12): the values of the verb's content parameters (`AdapterParameter.isContent`, a
    /// text written, appended, found or put in place), for this call only, as a text typed where no target was
    /// attested. A call whose verb cannot be resolved, or made without the adapters, is refused after its transcript
    /// line: every text of its arguments is withheld, since none was classified. The values of a verb's confidential
    /// parameters (`AdapterParameter.confidentiality`, P1-06: a mail's subject, body and recipients, a message, a note)
    /// are withheld from the records and the transcript as confidential content, field by field; its answers show them.
    private func contentScope(of arguments: JSONValue) -> CallScope {
        var scope = CallScope()
        let values = arguments["arguments"]
        let resolved = adapters.flatMap { adapters -> AdapterVerb? in
            guard let app = arguments["app"].string, let verb = arguments["verb"].string else { return nil }
            return try? adapters.resolve(app: app, verb: verb, arguments: values).verb
        }
        guard let resolved else {
            for text in ResultFormatter.texts(in: values) { ProducerSecrets.withholdContent(text, in: &scope) }
            return scope
        }
        for parameter in resolved.parameters where parameter.isContent {
            if let text = values[parameter.name].string { ProducerSecrets.withholdContent(text, in: &scope) }
        }
        for parameter in resolved.parameters where parameter.confidentiality != .ordinary {
            if let text = values[parameter.name].string { ProducerSecrets.withholdContent(text, in: &scope, recordsOnly: true) }
        }
        return scope
    }

    /// What a call on a confidential surface withholds from its records (P1-06): a typed text always, and any other text
    /// it names that is content the model read of the application (a message's subject, a person's name), never one of the
    /// application's own controls. What the producer saw or read on any confidential surface is withheld from every
    /// record anyway (`recordMinimization`). `open_session`, `windows` and `apps` name applications and keep their words.
    private func confidentialScope(of name: String, _ arguments: JSONValue, in scope: inout CallScope) {
        guard !["open_session", "windows", "apps", "status", "close_session", "app_capabilities"].contains(name),
              let application = session.memoryApplication, ConfidentialSurfaces.surface(of: application) != nil,
              let request = try? ToolArguments.callRequest(name, arguments == .null ? JSONValue.object([:]) : arguments)
        else { return }
        let content = Set(sceneText.seen.filter { $0.scene.bundleID == application }.flatMap { baseline in
            baseline.scene.elements.filter(ConfidentialSurfaces.isContent).flatMap { [$0.label] + ($0.value.map { [$0] } ?? []) }
        })
        let typed: Set<String> = ["text", "expected_value"]
        // The field a text is typed into is named by the application; what goes into it is content.
        let typesIntoField = ["type_text", "insert_text"].contains(name)
        for argument in request.arguments {
            guard case .text(let text) = argument.value, argument.name != "verb" else { continue }
            let named = typesIntoField && argument.name == "target" ? false : content.contains(text)
            if typed.contains(argument.name) || named || producerSecrets.confidentialValues.contains(text) {
                scope.withholdFromRecords(text, .confidentialContent)
            }
        }
    }

    private func toolCall(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        if name == MemoryTaskTool.name { return try await taskCycle.call(arguments) }
        if name == HumanStepTool.name {
            let request = try HumanStepTool.request(arguments)
            let result = await session.humanStep(request)
            return HumanStepTool.result(result, withholding: producerSecrets.withheld)
        }
        let before = sceneText.seen
        // A session that ended leaves no scene to compare the next one against.
        defer { if session.id == nil { sceneText.forgetScene() } }
        do {
            return try await dispatch(name, arguments)
        } catch {
            // A failed call reaches the model without its scenes, so the baseline stays the one it read.
            sceneText.keepBaseline(before)
            let guidance = session.id == nil
                ? "Use status and list current windows before opening a new session."
                : "Observe before any retry."
            try formatter.transcribe("← \(name) error: \(error). \(guidance)")
            throw error
        }
    }

    /// Runs the call under its recorder, when the session has a memory. A call that may change the
    /// application or the Seat is confirmed in the archive, planned and started with its admitted
    /// arguments and its task attribution, before any effect: when the memory does not confirm it, or
    /// cannot represent it, the call is refused and nothing is done. A read-only call runs whatever the
    /// memory answers, and its answer says when it was not recorded. The engine reports to the recorder
    /// through `CallRecorder.current`; the call's end carries the result the tool answered, or its error,
    /// with the check the operation's oracle made. An end the memory cannot save suspends it: the answer
    /// says so, the effect is never repeated, and no further effect starts until the end is saved.
    private func dispatch(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let arguments = arguments == .null ? JSONValue.object([:]) : arguments
        let request = try? ToolArguments.callRequest(name, arguments)
        guard let recorder = makeRecorder(sessionID: session.id) else {
            return try finish(name, try await answer(name, arguments, recorder: nil), notice: nil)
        }
        guard let request else {
            if AgentTool(rawValue: name)?.requiresConfirmedStart == true {
                // The call itself refuses such a request before any effect: let it say why, unrecorded.
                _ = try await answer(name, arguments, recorder: nil)
                throw AutomationFailure("Braus's memory cannot represent this call, so it was not run.")
            }
            return try finish(name, try await answer(name, arguments, recorder: nil),
                          notice: "This call was not recorded: Braus's memory cannot represent its arguments.")
        }
        // The contract refuses such a call before the memory is asked; it is said as what it is, nothing run or recorded.
        if request.tool.requiresConfirmedStart, request.tool.takesSession, session.id == nil { throw Self.noSession }
        // P2-06: an effect not known blocks its repeat and what depends on it, across restarts.
        let planned = request.tool == .batch
            ? (arguments["steps"].array ?? []).compactMap { try? Step(string($0, "operation"), $0).callRequest } : [request]
        let claim = try claimDataWrites(planned)
        defer { withExtendedLifetime(claim) {} }
        if let refusal = try await uncertaintyRefusal(planned) { throw AutomationFailure(refusal) }
        if let refusal = await historicalValueRefusal(name, arguments) { throw AutomationFailure(refusal) }
        let attribution = request.tool == .batch ? nil : taskCycle.openTask?.attribution
        if case .batch = request {} else {
            do {
                try await recorder.begin(request, app: application(of: request), attribution: attribution)
            } catch {
                await producerSecrets.collect(from: recorder)
                guard !request.tool.requiresConfirmedStart else { throw Self.unconfirmed(error) }
                let value = try await CallRecorder.$current.withValue(nil) {
                    try await self.answer(name, arguments, recorder: nil)
                }
                return try finish(name, value, notice: "This call was not recorded: \(error).")
            }
        }
        await producerSecrets.collect(from: recorder)
        do {
            let value = try await CallRecorder.$current.withValue(recorder) {
                try await self.answer(name, arguments, recorder: recorder)
            }
            // The notice is read after the end, which may itself be saved only in part.
            let notice: String?
            do {
                try await recorder.end(.completed, result: output.lastResult, tool: request.tool, check: output.lastCheck)
                notice = await recorder.recordingGap.map { "Part of this call was not recorded: \($0)." }
            } catch {
                notice = Self.suspended(error)
            }
            await producerSecrets.collect(from: recorder)
            return try finish(name, value, notice: notice)
        } catch {
            let cancelled = error is CancellationError
            let notice: String?
            do {
                try await recorder.end(cancelled ? .cancelled : .failed,
                                       result: cancelled ? nil : .error(message: String(describing: error)),
                                       tool: request.tool, check: output.lastCheck)
                notice = await recorder.recordingGap.map { "Part of this call was not recorded: \($0)." }
            } catch let failure {
                notice = Self.suspended(failure)
            }
            guard let notice else { throw error }
            try formatter.transcribe("← \(name) memory: \(notice)")
            // A cancelled call has no reader; any other failure reaches the model with what was not recorded.
            if cancelled { throw error }
            throw AutomationFailure("\(error) \(notice)")
        }
    }

    /// The refusal of a call that needs a session when none is open: the call's own contract, never the memory's failure
    /// (live run R01, Workspace event 113, where the agent read it as a memory that was not available).
    static let noSession = AutomationFailure("This call needs an open session and none is open, so nothing was done. Open one "
                                             + "with open_session, then call again.")

    /// The refusal of a call whose start the memory did not confirm: nothing was done.
    private static func unconfirmed(_ error: any Error) -> AutomationFailure {
        AutomationFailure(
            "Braus's memory did not confirm this call before it could act (\(error)), so nothing was done. "
                + "Braus records every action before taking it; use status, and try again once the memory is available."
        )
    }

    /// What the answer says when the end of a call that may have acted could not be saved.
    private static func suspended(_ error: any Error) -> String {
        "The action ran, but Braus's memory could not save its record (\(error)). Do not repeat the action: observe instead. "
            + "Braus takes no further action until the record is saved."
    }

    private func gatesUncertainty(_ request: AgentCallRequest) -> Bool {
        if case .appCall(let app, let verb, let arguments) = request,
           let value = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)),
           (try? adapters?.resolve(app: app, verb: verb, arguments: value).verb.safety) == .read {
            return false
        }
        return request.tool == .appCall
    }

    /// Reserves a producer's writes before the first suspension, covering the gate/start race across processes.
    /// Read-only calls remain available. The hold spans dispatch and recording, and dies with its process on a crash.
    private func claimDataWrites(_ requests: [AgentCallRequest], readOnly: Bool = false) throws -> AppClaims.Hold? {
        guard !readOnly, requests.contains(where: gatesUncertainty), let directory = session.memoryDirectory else { return nil }
        let identity = try JSONEncoder().encode([producer.source.rawValue, producer.streamID])
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let claims = AppClaims(namespace: directory.appending(path: "effect-claims", directoryHint: .isDirectory))
        switch claims.acquire(key, owner: UUID()) {
            case .success(let hold): return hold
            case .failure:
                throw AutomationFailure("Not run: another write in this producer context is running, or its coordination lock is unavailable. Wait for it to finish; nothing was sent.")
        }
    }

    /// Why `request` may not run now (P2-06): it repeats a call of this producer whose effect is not known, or acts on the
    /// resource such a call reached, and no later fact resolved it. A read-only call, and `memory_task`, always run. The
    /// refusal holds across restarts, since it reads the archive; what resolves it is `memory_task reconcile`.
    private func uncertaintyRefusal(
        _ requests: [AgentCallRequest]
    ) async throws -> String? {
        // A call with an oracle of its own (an adapter's) is what the gate holds: a UI gesture's unverified effect is read on
        // the next observation of the same window, and a repeat there is the agent's reading of it.
        guard requests.contains(where: gatesUncertainty), let directory = session.memoryDirectory else { return nil }
        let memory = MemoryService.shared(for: directory)
        let executor = MemoryExecutor.current(for: directory, source: producer.source)
        if let executor { await MemoryExecutor.sweep(memory, folder: directory, current: executor) }
        // A pending call of this executor can still act; it must block a concurrent repeat too. Read errors fail closed.
        let unresolved = try await memory.unresolvedCalls(source: producer.source, streamID: producer.streamID,
                                                         excludingExecutor: nil).filter { gatesUncertainty($0.request) }
        for call in unresolved {
            for request in requests where gatesUncertainty(request) {
                let repeats = call.isRepeated(by: request)
                if repeats {
                    return "Not run: it repeats call \(call.eventID), whose effect is not known (\(call.reason.rawValue)). Read "
                        + "whether it happened, then memory_task reconcile {call, finding, evidence}; nothing was sent."
                }
                if call.isDepended(on: request) {
                    return "Not run: it acts on what call \(call.eventID) reached, whose effect is not known. Read it first, "
                        + "then memory_task reconcile {call, finding, evidence}; nothing was sent."
                }
            }
        }
        return nil
    }

    /// Why an adapter's call may not run now (P2-02): within an open task, an argument is an identifier another run's
    /// result produced, which no result of this run and no input of its task holds. A run uses its own results; a value
    /// of the history is not taken implicitly, missing or not. Reading it again in this run, or naming it as an input
    /// of the task, lets the call run.
    private func historicalValueRefusal(_ name: String, _ arguments: JSONValue) async -> String? {
        guard name == "app_call", let task = taskCycle.openTask, let directory = session.memoryDirectory else { return nil }
        let values = StructuredLeaves.fields(of: arguments["arguments"]).filter { $0.kind == .text || $0.kind == .number }
            .compactMap(\.text).filter { !$0.isEmpty }
        guard !values.isEmpty,
              let found = try? await MemoryService.shared(for: directory).historicalValues(values, attemptID: task.attemptID),
              let value = found.first else { return nil }
        return "Not run: '\(value)' is an identifier another run produced, and nothing in this run read or named it. Read it "
            + "in this run (or name it as an input of the task) before using it; nothing was sent."
    }

    /// The recorder of one call over this session's memory, under the producer and its current trace.
    private func makeRecorder(sessionID: UUID?, parent: CallRecorder? = nil, position: Int? = nil) -> CallRecorder? {
        guard let directory = session.memoryDirectory else { return nil }
        let service = MemoryService.shared(for: directory)
        let brain   = BrainMemory(brains: service, applications: service, relations: service,
                                  clock: { service.clock.brainNow() })
        let context: ActionContext
        if let parent, let position {
            context = parent.context.child(position)
        } else {
            context = ActionContext(source: producer.source, streamID: producer.streamID, traceID: producer.traceID,
                                    sessionID: sessionID?.uuidString)
        }
        return CallRecorder(
            memory      : service,
            brain       : brain,
            context     : context,
            minimization: producerSecrets.recordMinimization
        )
    }

    /// The application the session holds, as a call's event names it.
    private var memoryApplication: AppContextIdentity? {
        session.memoryApplication.map { AppContextIdentity(bundleID: $0) }
    }

    /// The application a call's event names: the adapter's app for the adapter tools, which run
    /// outside the session, and the session's app for every other tool.
    private func application(of request: AgentCallRequest) -> AppContextIdentity? {
        switch request {
            case .appCapabilities(let app, _), .appCall(let app, _, _):
                return adapters?.adapter(for: app)?.bundleIDs.sorted().first.map { AppContextIdentity(bundleID: $0) }
            default:
                return memoryApplication
        }
    }

    private func answer(_ name: String, _ arguments: JSONValue, recorder: CallRecorder?) async throws -> JSONValue {
        output.lastResult = nil
        output.lastCheck  = nil
        output.transcriptOmits = []
        output.contentTexts    = []
        output.modelText       = nil
        let arguments = arguments == .null ? JSONValue.object([:]) : arguments
        guard let definition = toolDefinitions.first(where: { $0["name"].string == name }),
              let values = arguments.object else { throw AutomationFailure("Invalid tool arguments.") }
        let schema = definition["inputSchema"]
        let allowed = Set(schema["properties"].object?.keys.map { $0 } ?? [])
        guard Set(values.keys).isSubset(of: allowed) else { throw AutomationFailure("Unknown tool argument.") }
        for field in schema["required"].array ?? [] {
            guard let key = field.string, values[key] != nil else { throw AutomationFailure("A required argument is missing.") }
        }
        try formatter.transcribe("→ \(name)", arguments)
        let value: JSONValue
        if !["status", "windows", "apps", "open_session", "app_capabilities", "app_call"].contains(name) {
            guard let id = session.id, arguments["session"].string == id.uuidString else {
                throw AutomationFailure("Session ID is missing or stale. Use status; open a session if necessary and observe again.")
            }
        }
        switch name {
        case "status":
            let screen = Permissions.preflight(.screenRecording), access = Permissions.preflight(.accessibility)
            let post = Permissions.preflight(.postEvent)
            value = .object(["session": session.id.map { .string($0.uuidString) } ?? .null,
                "permissions": .object([
                    "screenRecording": .bool(screen),
                    "accessibility": .bool(access),
                    "postEvent": .bool(post)
                ])])
            output.lastResult = .status(StatusResult(sessionID: session.id?.uuidString, screenRecording: screen,
                                              accessibility: access, postEvent: post))
        case "windows":
            let apps: [NSRunningApplication]
            if values["app"] != nil {
                let word = try string(arguments, "app")
                do {
                    apps = [try RunningApplicationLookup.running(word)]
                } catch {
                    // An application installed but not running has no window yet: say so, and how to open it, instead of an
                    // error the agent answers with another listing (10 of 30 runs on PhotoCraft, 14 October 2026).
                    let offered = (try? await session.applications(matching: word)) ?? []
                    guard let first = offered.first else { throw error }
                    value = .object(["applications": .array([]),
                                     "not_running": .array(offered.prefix(3).map(ToolArguments.candidate)),
                                     "next": .string("\(first.name) is not running, so it has no window: open it with open_session "
                                                     + "{app: \"\(first.bundleID)\"}.")])
                    output.lastResult = .listing(ListingResult(kind: .windows, applications: []))
                    break
                }
            }
            else { apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular } }
            var listed: [ListedApplication] = []
            var entries: [JSONValue] = []
            for app in apps {
                let rows = try await session.windowCandidates(ownedBy: app.processIdentifier)
                listed.append(ListedApplication(
                    name: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "", pid: Int64(app.processIdentifier),
                    windows: rows.map { ListedWindow(number: Int64($0.number), title: $0.title ?? "") }
                ))
                entries.append(.object(["name": .string(app.localizedName ?? ""),
                    "bundleID": .string(app.bundleIdentifier ?? ""), "pid": .number(Double(app.processIdentifier)),
                    "windows": .array(rows.map { .object(["id": .number(Double($0.number)),
                                                         "title": .string($0.title ?? "")]) })]))
            }
            value = .object(["applications": .array(entries)])
            output.lastResult = .listing(ListingResult(kind: .windows, applications: listed))
        case "apps":
            let found = try await session.applications(matching: optionalString(arguments, "query"))
            let shown = found.prefix(ToolArguments.applicationLimit)
            var listing: [String: JSONValue] = ["applications": .array(shown.map(ToolArguments.candidate))]
            if found.count > shown.count {
                listing["more"] = .string("\(found.count - shown.count) more not listed; pass a query to find them.")
            }
            value = .object(listing)
            output.lastResult = .listing(ListingResult(kind: .apps, applications: shown.map {
                ListedApplication(name: $0.name, bundleID: $0.bundleID, version: $0.version, isRunning: $0.isRunning,
                                  location: $0.location, isDefaultBrowser: $0.isDefaultBrowser)
            }, hiddenCount: found.count - shown.count))
        case "app_capabilities":
            let listing = try await enabledAdapters().capabilities(of: string(arguments, "app"),
                                                                   query: try optionalString(arguments, "query"))
            value = listing.json
            output.modelText = listing.text
        case "app_call":
            let adapters = try enabledAdapters()
            let app = try string(arguments, "app"), verb = try string(arguments, "verb")
            let resolved = try? adapters.resolve(app: app, verb: verb, arguments: arguments["arguments"])
            output.transcriptOmits = resolved?.verb.contentResults ?? []
            // P2-02: the argument object's leaves, minimized at the end; the archive decides which name an earlier result.
            await recorder?.noted(arguments: StructuredLeaves.fields(of: arguments["arguments"]))
            // P2-03: once the adapter runs its effect is not known until it answers; a throw keeps it so.
            if let resolved {
                output.lastCheck = OperationCheck(condition: resolved.verb.safety == .read ? .adapterRead : .adapterEffect,
                                           method: .adapterReadBack, methodVersion: OperationCheck.adapterVersion,
                                           verdict: .unknown, limits: [.deliveryUncertain], performed: .uncertain)
                await recorder?.noted(context: ResultFormatter.dataContext(of: resolved, arguments: arguments["arguments"], result: nil))
            }
            // The adapter verb is noted right before the adapter runs, never for a call its guards refused (M05).
            let outcome: AdapterOutcome
            do {
                if let refusal = adapters.seatConflict(app: app, held: session.memoryApplication, elsewhere: SeatHolds.bundleIDs) {
                    outcome = .refused(refusal)
                } else {
                    outcome = try await adapters.call(app: app, verb: verb, arguments: arguments["arguments"]) { dispatch in
                        await recorder?.dispatched(adapter: dispatch)
                    }
                }
            } catch {
                guard let verb = resolved?.verb, verb.resultConfidentiality != .ordinary,
                      !(error is CancellationError) else { throw error }
                throw AutomationFailure("The adapter failed; its confidential error details were withheld.")
            }
            // A confidential verb's result (P1-06) is the model's: its fields are withheld from the record and the
            // transcript, each value whole and the long ones wherever they appear (the outcome's message among them).
            if let verb = resolved?.verb, verb.resultConfidentiality != .ordinary {
                await producerSecrets.withholdConfidential(verb.confidentialTexts(of: outcome.result), from: recorder)
            }
            if let resolved {
                output.lastCheck = outcome.check(for: resolved.verb)
                // A file's content a verb answered (P12) is the model's only: its leaves are withheld, as its transcript's.
                let content = Set(resolved.verb.contentResults)
                await recorder?.noted(results: StructuredLeaves.fields(of: outcome.result).map { leaf in
                    content.contains(where: { leaf.path == "/" + StructuredLeaves.escape($0) || leaf.path.hasPrefix("/" + StructuredLeaves.escape($0) + "/") })
                        ? leaf.withholding(.confidentialContent) : leaf
                })
                await recorder?.noted(context: ResultFormatter.dataContext(of: resolved, arguments: arguments["arguments"],
                                                                result: outcome.result))
            }
            output.modelText = AdapterText.outcome(outcome)
            output.contentTexts = ResultFormatter.content(of: resolved?.verb, arguments: arguments["arguments"], outcome: outcome)
            value = outcome.json.adding("evidence", ResultFormatter.evidence(output.lastCheck, kind: outcome.kind))
            output.lastResult = .outcome(outcome.kind, message: outcome.message)
        case "open_session":
            if values["named"] != nil, arguments["named"].bool == nil {
                throw AutomationFailure("named must be true or false.")
            }
            let app = try string(arguments, "app")
            let decision = await route(opening: app, named: arguments["named"].bool == true)
            switch decision {
                case .use(let route, let message):
                    value = .object(["opened": .bool(false), "route": .string(route.address), "message": .string(message)])
                    // Nothing opened, so no scene: the record keeps the call as completed with no observation, and
                    // the decision as the call's advice, written with its end (M05).
                    await recorder?.advised(CallRouteAdvice(decision: .use, route: route.address, message: message))
                    output.lastResult = nil
                case .ask(let question):
                    value = .object(["opened": .bool(false), "ask": .string(question)])
                    await recorder?.advised(CallRouteAdvice(decision: .ask, route: nil, message: question))
                    output.lastResult = nil
                case .open(let note):
                    // The router's note is its decision's words (why the interface and not an adapter, or the advice
                    // on a contact's channel): handed to the call's recorder before anything opens, so it stays the
                    // call's fact whether the opening then succeeds or fails (M05). The route row is the dispatch.
                    if let note { await recorder?.advised(CallRouteAdvice(decision: .open, route: nil, message: note)) }
                    await noteDispatch()
                    do {
                        let scene = try await session.open(application: app, window: ToolArguments.windowTitle(arguments))
                        value = await observation(scene).adding("routeNote", note.map(JSONValue.string))
                        output.lastResult = await observed(by: recorder)
                    } catch is CancellationError where AutomationCallInterruption.current?.wasInterrupted == true {
                        guard let id = session.id else { throw CancellationError() }
                        sceneText.forgetScene()
                        value = .object([
                            "opened": .bool(true), "session": .string(id.uuidString),
                            "note": .string("The person took control after the session opened. No scene was read. "
                                + "Observe this session after control returns before acting.")
                        ]).adding("routeNote", note.map(JSONValue.string))
                        output.lastResult = nil
                    }
            }
        case "observe":
            if values["full"] != nil, arguments["full"].bool == nil {
                throw AutomationFailure("full must be true or false.")
            }
            await noteDispatch()
            let scene = try await session.observe()
            value = await observation(scene, changesOnly: arguments["full"].bool != true)
            output.lastResult = await observed(by: recorder)
        case "menu":
            await noteDispatch()
            let done = try await session.menu(path: string(arguments, "path"))
            value = await outcome(done)
            output.lastResult = .outcome(done.kind, message: done.message)
            output.lastCheck  = done.withStatedCheck.check
        case "press":
            await noteDispatch()
            let done = try await session.press(button: string(arguments, "button"))
            value = await outcome(done)
            output.lastResult = .outcome(done.kind, message: done.message)
            output.lastCheck  = done.withStatedCheck.check
        case "collect_posts":
            guard case .collectPosts(let target, let maxScrolls, let seconds) = try ToolArguments.callRequest(name, arguments)
            else {
                throw AutomationFailure("Invalid tool arguments.")
            }
            await noteDispatch()
            let collected = try await session.collectPosts(
                PostCollectionRequest(target: target, maxScrolls: maxScrolls, seconds: Double(seconds)))
            value = ResultFormatter.collection(collected)
        case "act", "select", "type_text", "insert_text", "press_key", "scroll", "drag", "context_menu":
            let step = try Step(name, arguments)
            let done = try await perform(step, dispatch: CallScope.current.dispatch(of: step.texts, at: 0))
            value = await outcome(done)
            output.lastResult = .outcome(done.kind, message: done.message)
            output.lastCheck  = done.withStatedCheck.check
        case "batch":
            guard let rows = arguments["steps"].array, (1...20).contains(rows.count) else {
                throw AutomationFailure("batch requires 1...20 steps.")
            }
            let steps = try rows.map { try Step(string($0, "operation"), $0) }
            // Each step is a call of its own, the batch's child at its position, recorded planned with it.
            let children = recorder.map { parent in
                steps.indices.compactMap { makeRecorder(sessionID: session.id, parent: parent, position: $0) }
            }
            if let recorder, let children, children.count == steps.count {
                do {
                    try await recorder.begin(
                        batch      : zip(children, steps).map { ($0, $1.callRequest) },
                        app        : memoryApplication,
                        attribution: taskCycle.openTask?.attribution
                    )
                } catch {
                    for child in children { await producerSecrets.collect(from: child) }
                    throw Self.unconfirmed(error)
                }
                for child in children { await producerSecrets.collect(from: child) }
            }
            var results: [JSONValue] = []
            var complete = true
            var verified = 0
            // The steps that started: a step the memory refused to start never ran, and is skipped.
            var started  = 0
            var memoryNotice: String?
            // Steps saved only in part: said in the answer, without stopping the batch as a suspension does.
            var stepGaps: [String] = []
            func noteGap(of child: CallRecorder?, at index: Int) async {
                guard let gap = await child?.recordingGap else { return }
                stepGaps.append("Part of step \(index + 1) was not recorded: \(gap).")
            }
            for (index, step) in steps.enumerated() {
                if Task.isCancelled {
                    // The cancellation ends the call as before; the steps it leaves unrun are recorded as never
                    // run, as after a stop, so none stays planned in the memory.
                    for child in (children ?? []).dropFirst(started) { try? await child.skip() }
                    throw CancellationError()
                }
                let child = children?.indices.contains(index) == true ? children?[index] : nil
                if let child {
                    do {
                        try await child.startStep()
                    } catch {
                        complete = false
                        results.append(.object(["status": .string("error"),
                                                "message": .string(Self.unconfirmed(error).description),
                                                "guidance": .string("This step was not run. Earlier effects remain.")]))
                        try formatter.transcribe("← batch step \(index + 1) not run: \(error)")
                        break
                    }
                }
                started += 1
                let result: ActOutcome
                let dispatch = CallScope.current.dispatch(of: step.texts, at: index)
                do { result = try await CallRecorder.$current.withValue(child) { try await self.perform(step, dispatch: dispatch) } }
                catch {
                    do {
                        try await child?.end(
                            error is CancellationError ? .cancelled : .failed,
                            result: error is CancellationError ? nil : .error(message: String(describing: error)),
                            tool  : step.callRequest.tool
                        )
                    } catch let failure {
                        memoryNotice = Self.suspended(failure)
                    }
                    await noteGap(of: child, at: index)
                    let guidance = session.id == nil
                        ? "Earlier effects remain. Use status and list current windows before opening a new session."
                        : "Earlier effects remain. Observe before deciding the next step."
                    let failed: JSONValue = .object(["status": .string("error"), "message": .string(String(describing: error)),
                        "guidance": .string(guidance)])
                    results.append(failed)
                    try formatter.transcribe("← batch step \(index + 1) error: \(error)")
                    complete = false
                    break
                }
                let value = await outcome(result)
                results.append(value)
                do {
                    try await child?.end(.completed, result: .outcome(result.kind, message: result.message),
                                         tool: step.callRequest.tool, check: result.withStatedCheck.check)
                } catch {
                    memoryNotice = Self.suspended(error)
                }
                await noteGap(of: child, at: index)
                if let child { await producerSecrets.collect(from: child) }
                try formatter.transcribe("← batch step \(index + 1)", value)
                let accepted = result.kind == .foundActed
                    || (result.kind == .actedNoop && step.isToggle)
                if !accepted || memoryNotice != nil { complete = false; break }
                verified += 1
            }
            for child in (children ?? []).dropFirst(started) {
                do { try await child.skip() } catch { memoryNotice = memoryNotice ?? Self.suspended(error) }
            }
            var summary: [String: JSONValue] = ["status": .string(complete ? "completed" : "stopped"),
                                                "steps": .array(results),
                                                "attemptedSteps": .number(Double(started)),
                                                "verifiedSteps": .number(Double(verified)),
                                                "requested": .number(Double(steps.count))]
            let notes = (memoryNotice.map { [$0] } ?? []) + stepGaps
            if !notes.isEmpty { summary["memory"] = .string(notes.joined(separator: " ")) }
            value = .object(summary)
            output.lastResult = .batch(stopped: !complete, attempted: started, verified: verified)
        case "close_session":
            await session.close()
            var result: [String: JSONValue] = ["status": .string("closed"),
                                               "message": .string("Application session closed.")]
            if let warning = session.closeWarning { result["warning"] = .string(warning) }
            value = .object(result)
            output.lastResult = .closed(message: "Application session closed.")
        default: throw AutomationFailure("Unknown tool: \(name)")
        }
        return value
    }

    private func route(opening app: String, named: Bool) async -> RouteDecision {
        guard let router, !named else { return .open(note: nil) }
        let bundleID = await session.resolvedBundleID(of: app)
        if let bundleID, bundleID == session.memoryApplication { return .open(note: nil) }
        return router.route(opening: app, bundleID: bundleID, named: named, context: await routeContext())
    }

    /// What the router knows of this Mac for one decision: the adapters of this build and whether each
    /// can run now.
    private func routeContext() async -> RouteContext {
        var available: [String: RouteAvailability] = [:]
        for (adapter, availability) in await adapters?.listing() ?? [] {
            available[adapter.name] = switch availability {
                case .ready                      : .ready
                // An unknown grant is not readiness (R04); the verb checks it before any event, so the adapter stays
                // the route and the router says so.
                case .unknown(let reason)        : .unknown(reason)
                case .needsPermission(let reason): .notReady(reason)
                case .unavailable(let reason)    : .notReady(reason)
            }
        }
        return RouteContext(adapters: available, webAvailable: channels.contains(.web))
    }

    /// The adapters, or the refusal of an adapter tool in a composition without them.
    private func enabledAdapters() throws -> AppAdapters {
        guard let adapters else {
            throw AutomationFailure("App adapters are not enabled in this Braus: open the app with open_session instead.")
        }
        return adapters
    }

    /// The typed answer of an observation the recorder wrote as a sample: nil when it wrote none, which
    /// the record keeps as an explicit gap.
    private func observed(by recorder: CallRecorder?) async -> AgentCallResult? {
        guard let recorder, let id = session.id, let sample = await recorder.lastObservation else { return nil }
        return .observation(ObservationResult(sessionID: id.uuidString, sessionRevision: Int64(sceneText.revision),
                                              observedAtMS: recorder.memory.clock.calendarMS(), sample: sample))
    }

    /// Notes, for the current call, the route of a session no routing session fronts, right where the call reaches the
    /// session (M05). A routing session reports its own route, with a hand-back's reason, and the note never replaces
    /// it; a call refused before it reaches the session (a stale ID, a redirect, a question, a listing) notes nothing.
    private func noteDispatch() async {
        await Self.noteDispatch(session: session)
    }

    static func noteDispatch(session: any AutomationSessionOperating) async {
        await CallRecorder.current?.noted(profile: session.dataProfile)
        guard let route = session.dispatchRoute else { return }
        await CallRecorder.current?.dispatched(unrouted: route)
    }

    /// Runs a step; a text step the call classified goes as `dispatch` says: bound to its field, or withheld.
    private func perform(_ step: Step, dispatch: TextDispatch? = nil) async throws -> ActOutcome {
        await noteDispatch()
        switch step {
        case .act(let target, let verb, let section, let state):
            return try await session.act(target: target, verb: verb, section: section, desiredState: state)
        case .select(let control, let item):
            return try await session.select(control: control, item: item)
        case .input(let input, let section):
            if let dispatch { return try await session.deliver(input, section: section, dispatch: dispatch) }
            return try await session.deliver(input, section: section)
        }
    }

    private func string(_ object: JSONValue, _ key: String) throws -> String {
        try ToolArguments.requiredString(object, key)
    }

    private func optionalString(_ object: JSONValue, _ key: String) throws -> String? {
        try ToolArguments.optionalString(object, key)
    }

}

struct CallOutput {
    /// The typed result of the call `answer` concluded last, for its record.
    var lastResult: AgentCallResult?

    /// The check the last operation's path reported, for its record.
    var lastCheck: OperationCheck?

    /// The result keys of the call `answer` concluded last that hold content (`AdapterVerb.contentResults`): left out
    /// of the transcript line of its answer, never out of the answer.
    var transcriptOmits: [String] = []

    /// The content texts of the adapter call `answer` concluded last (`content(of:arguments:outcome:)`): withheld
    /// from its record and its transcript line, never from the answer.
    var contentTexts: [String] = []

    /// The answer of the adapter call `answer` concluded last as the model reads it, nil for every other tool.
    var modelText: String?

}

