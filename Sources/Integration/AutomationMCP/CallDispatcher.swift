import Capabilities
import ChatCore
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
import Switches

/// CallDispatcher runs a call in its scope and recorder, borrowing state kept alive by the facade.
final class CallDispatcher {
    private let session: any AutomationSessionOperating
    private(set) var registry: CapabilityRegistry
    private let providers: [String: any CapabilityProviding]
    private let recording: (any CapabilityRecording)?
    let toolList: ToolList
    private let surface: ToolSurface
    private let usesFixedList: Bool
    private var guides: AppGuides?
    private let resolveGuideApp: @MainActor @Sendable (String) -> OpenedApp
    private var guideProvider: GuideCapability?
    private var directNames: Set<String> = []

    @TaskLocal
    static var presentation: CallPresentation?

    @MainActor
    final class CallPresentation {
        var head: GuideHead?
        var index: GuideIndex?
        var notices: [String] = []
    }
    private var search: CapabilitySearch?
    private var frozenDefinitions: [JSONValue] = []
    private var callableDefinitions: [JSONValue] = []
    private(set) var entries: [CatalogueEntry] = []
    private let channels: AutomationChannels
    var adapters: AppAdapters? {
        didSet { rebuildRegistry() }
    }
    var router: TaskRouter? {
        didSet { rebuildRegistry() }
    }
    private unowned let producerSecrets: ProducerSecrets
    private unowned let sceneText: SceneTextPolicy
    private unowned let taskCycle: TaskCycleHandler
    private unowned let formatter: ResultFormatter
    private var output = CallOutput()
    var taskStateSink: TaskStateSink?
    private var callSequence = 0

    @TaskLocal
    static var taskStateCall: TaskStateCall?

    /// TaskStateCall isolates typed observations across suspended or concurrent calls.
    @MainActor
    final class TaskStateCall {
        var facts: [TaskStateInput.Fact] = []
        var loaded: [TaskStateInput.LoadedItem] = []
        let tool: String

        init(tool: String) {
            self.tool = tool
        }
    }
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
        formatter: ResultFormatter,
        capabilities: [any CapabilityProviding],
        recording: (any CapabilityRecording)?,
        loading: ToolLoading = .upfront,
        list: ToolList = .init(attendance: .none, level: .actConnectors),
        guides: AppGuides? = nil,
        resolveGuideApp: @escaping @MainActor @Sendable (String) -> OpenedApp = {
            OpenedApp(bundleID: $0, version: nil, locale: Locale.current.identifier)
        }
    ) {
        self.toolList = list
        self.surface = ToolCatalogue.currentSurface
        self.usesFixedList = ToolCatalogue.currentSurface == .v2 && TaskCycleArm.current == .v2
        self.guides = guides
        self.resolveGuideApp = resolveGuideApp
        var providers: [String: any CapabilityProviding] = [:]
        var registered: [CapabilityContract] = []
        for provider in capabilities {
            let family = provider.family
            let contracts = provider.contracts.map(ToolCatalogue.composedContract)
            precondition(!family.isEmpty && !family.contains("."), "A capability family must be one name")
            precondition(providers[family] == nil, "Duplicate capability family: \(family)")
            precondition(contracts.allSatisfy {
                $0.origin == .registered(provider: family) && $0.id.rawValue.hasPrefix(family + ".")
            }, "Capability contracts must belong to their provider family")
            providers[family] = provider
            registered += contracts
        }
        do {
            self.registry = try CapabilityRegistry(
                core: ToolCatalogue.contracts(for: channels, adapters: adapters),
                registered: registered
            )
        } catch {
            preconditionFailure("Invalid capability composition: \(error)")
        }
        self.providers = providers
        self.recording = recording
        self.session = session
        self.channels = channels
        self.adapters = adapters
        self.router = router
        self.producerSecrets = secrets
        self.sceneText = sceneText
        self.taskCycle = taskCycle
        self.formatter = formatter
        if let provider = guides?.capability(resolve: resolveGuideApp, todo: { taskCycle.todo?.rows.map(\.title) ?? [] }) {
            self.guideProvider = provider
            do { self.registry = try CapabilityRegistry(core: registry.all + provider.contracts, registered: []) }
            catch { preconditionFailure("Invalid guide composition: \(error)") }
        }
        self.entries = ToolCatalogue.catalogue(channels: channels, registry: registry).filter { permits($0.contract) }
        self.search = CapabilitySearch(entries: entries)
        self.frozenDefinitions = definitions(surface: surface)
        self.callableDefinitions = frozenDefinitions + entries.map { entry in
            .object(["name": .string(entry.contract.id.rawValue), "description": .string(entry.contract.description),
                "inputSchema": entry.contract.inputSchema,
                "annotations": .object(["readOnlyHint": .bool(entry.contract.effect == .read)])])
        } + ToolCatalogue.availableDefinitions(for: served, surface: surface).filter {
            ToolCatalogue.adapterTools.contains($0["name"].string ?? "")
        }
        let directDefinitions = loading == .harnessSearch
            ? ToolCatalogue.harnessDefinitions(core: frozenDefinitions, entries: entries, list: list)
            : frozenDefinitions
        self.directNames = Set(directDefinitions.compactMap { $0["name"].string })
    }

    /// Installs profile guides prepared before the first call, retaining the session's fixed tool list.
    func installProfileGuides(_ guides: AppGuides) throws {
        guard self.guides == nil else { return }
        let taskCycle = self.taskCycle
        if let provider = guides.capability(resolve: resolveGuideApp, todo: { taskCycle.todo?.rows.map(\.title) ?? [] }) {
            registry = try CapabilityRegistry(core: registry.all + provider.contracts, registered: [])
            guideProvider = provider
        }
        self.guides = guides
        entries = ToolCatalogue.catalogue(channels: channels, registry: registry).filter { permits($0.contract) }
        search = CapabilitySearch(entries: entries)
        callableDefinitions += entries.filter { $0.contract.id.rawValue == "read_guide" }.map { entry in
            .object(["name": .string(entry.contract.id.rawValue), "description": .string(entry.contract.description),
                "inputSchema": entry.contract.inputSchema,
                "annotations": .object(["readOnlyHint": .bool(entry.contract.effect == .read)])])
        }
    }

    private func rebuildRegistry() {
        guard !usesFixedList else { return }
        let registered = registry.all.filter {
            if case .registered = $0.origin { return true }
            return false
        }
        do {
            registry = try CapabilityRegistry(
                core: ToolCatalogue.contracts(for: served, adapters: adapters) + (guideProvider?.contracts ?? []),
                registered: registered
            )
        } catch {
            preconditionFailure("Invalid capability composition: \(error)")
        }
    }

    /// The channels this instance serves: those composed, `.adapters` while `adapters` is set and `.web` while
    /// `router` is and the web is composed.
    var served: AutomationChannels {
        var served = channels.subtracting([.web, .adapters])
        if adapters != nil { served.insert(.adapters) }
        if router != nil, channels.contains(.web) { served.insert(.web) }
        return served
    }

    var guidesEnabled: Bool { guides != nil }

    var toolDefinitions: [JSONValue] {
        usesFixedList ? frozenDefinitions : definitions(surface: surface)
    }

    func installSearch(_ search: CapabilitySearch) { self.search = search }

    private func permits(_ contract: CapabilityContract) -> Bool {
        switch toolList.level {
        case .observe: return contract.effect == .read
        case .act: return contract.channel != .connector
        case .actConnectors: return true
        }
    }

    /// Validates against all callable contracts while advertising only the frozen core list.
    private func callDefinitions(surface: ToolSurface) -> [JSONValue] {
        usesFixedList ? callableDefinitions : definitions(surface: surface)
    }

    private func definitions(surface: ToolSurface) -> [JSONValue] {
        if usesFixedList {
            return ToolCatalogue.definitions(for: toolList, channels: channels)
        }
        let definitions = ToolCatalogue.definitions(for: served, surface: surface) + registry.all.compactMap { contract in
            guard case .registered = contract.origin, permits(contract) else { return nil }
            return .object([
                "name": .string(contract.id.rawValue),
                "description": .string(contract.description),
                "inputSchema": contract.inputSchema,
                "annotations": .object(["readOnlyHint": .bool(contract.effect == .read)])
            ])
        }
        guard TaskCycleArm.current == .v2 else { return definitions }
        return definitions.map { definition in
            guard let name = definition["name"].string, registeredContract(name)?.effect != .read,
                  registeredContract(name) != nil, var tool = definition.object,
                  var schema = tool["inputSchema"]?.object, var fields = schema["properties"]?.object else { return definition }
            fields["step"] = .object(["type": .string("string"), "pattern": .string("^r[1-9][0-9]*$")])
            schema["properties"] = .object(fields)
            tool["inputSchema"] = .object(schema)
            return .object(tool)
        }
    }

    func resolvedCall(_ name: String, arguments: JSONValue, validatingArguments: Bool = true) throws -> (name: String, arguments: JSONValue) {
        try validateDirectName(name)
        guard name == "call", surface == .v2 else { return (name, arguments) }
        guard let target = arguments["name"].string, !["call", "find", "human_step"].contains(target),
              let contract = entries.first(where: { $0.contract.id.rawValue == target })?.contract, permits(contract),
              Set(arguments.object?.keys.map { $0 } ?? []).isSubset(of: ["name", "arguments"]) else { throw unknownTool() }
        if validatingArguments { try validate(arguments["arguments"], contract: contract) }
        return (target, arguments["arguments"])
    }

    private func validateDirectName(_ name: String) throws {
        guard usesFixedList else { return }
        guard directNames.contains(name) else { throw unknownTool() }
    }

    private func unknownTool() -> AutomationFailure {
        AutomationFailure(ModelText.text(.init(rawValue: "catalogue.unknown")), cause: "unknown_tool")
    }

    private func consumesRoutingStep(_ contract: CapabilityContract) -> Bool {
        TaskCycleArm.current == .v2 && contract.effect != .read
            && contract.inputSchema["properties"]["step"] == .object([
                "type": .string("string"), "pattern": .string("^r[1-9][0-9]*$")])
    }

    private func validate(_ arguments: JSONValue, contract: CapabilityContract) throws {
        var arguments = ToolArguments.admitted(arguments, surface: surface)
        var schema = contract.inputSchema
        if consumesRoutingStep(contract),
           var input = schema.object, var properties = input["properties"]?.object {
            _ = try ToolArguments.step(in: arguments)
            if var fields = arguments.object {
                fields.removeValue(forKey: "step")
                arguments = .object(fields)
            }
            properties.removeValue(forKey: "step")
            input["properties"] = .object(properties)
            schema = .object(input)
        }
        if let problem = SchemaValidation.firstProblem(arguments, schema: schema) {
            throw AutomationFailure(
                ModelText.schemaProblem(problem, minimizing: producerSecrets.recordMinimization),
                cause: "invalid_arguments"
            )
        }
    }

    private func registeredContract(_ name: String) -> CapabilityContract? {
        guard let contract = registry.contract(for: CapabilityID(rawValue: name)),
              case .registered = contract.origin else { return nil }
        return contract
    }

    private func finish(
        surface: ToolSurface,
        _ name: String,
        _ value: JSONValue,
        notice: String?
    ) throws -> JSONValue {
        try formatter.finish(
            name,
            value,
            notice: notice,
            output: output,
            surface: surface,
            guideHead: Self.presentation?.head, guideIndex: Self.presentation?.index
        )
    }

    private func refusalContext(tool: String, arguments: JSONValue) -> ResultFormatter.RefusalContext? {
        guard let id = session.id, let window = session.observedWindowNumber else { return nil }
        return ResultFormatter.RefusalContext(sessionID: id, windowNumber: window, tool: tool, arguments: arguments)
    }

    private func outcome(
        surface: ToolSurface,
        _ value: ActOutcome,
        refusal: ResultFormatter.RefusalContext?
    ) async -> JSONValue {
        let stable = refusal.flatMap {
            $0.sessionID == session.id && $0.windowNumber == session.observedWindowNumber ? $0 : nil
        }
        noteOutcome(value, tool: refusal?.tool)
        return await formatter.outcome(value, refusal: stable, surface: surface)
    }

    private func noteOutcome(_ value: ActOutcome, tool: String? = nil, personInControl: Bool = false) {
        if let call = Self.taskStateCall {
            let tool = tool ?? call.tool
            if value.kind == .refused && !personInControl {
                call.facts.append(.callFailed(tool: tool, reason: value.cause ?? value.outcome.row))
            } else {
                let label = value.check?.target?.label
                call.facts.append(.callFinished(tool: tool,
                    subject: label.map { producerSecrets.recordMinimization.minimize(text: $0).0 },
                    outcome: value.outcome))
            }
        }
    }

    private func observation(
        _ scene: SceneSnapshot,
        changesOnly: Bool = false,
        nested: Bool = false
    ) async -> JSONValue {
        if let id = session.id, let window = session.observedWindowNumber {
            formatter.noteScene(scene, sessionID: id, windowNumber: window)
        }
        return await sceneText.answer(
            scene,
            changesOnly: changesOnly,
            nested: nested,
            session: session,
            shown: producerSecrets.shownMinimization
        ).observation(nested: nested)
    }

    /// Runs one tool call. Before anything of it is written (its transcript line, its record), the texts it would
    /// type are classified on a fresh perception (`scope(of:_:)`, W1): what the call withholds and the field each
    /// text step is bound to are its `CallScope`, bound from there to its last output, the error it throws included.
    func call(
        _ name: String,
        _ arguments: JSONValue,
        surface requestedSurface: ToolSurface? = nil
    ) async throws -> JSONValue {
        try BatchMode.validateConfiguration()
        let surface = requestedSurface ?? self.surface
        // runCall validates the target inside its task-state observation, so direct and
        // delegated invalid calls publish the same failure. Host admission keeps eager validation.
        let resolved = try resolvedCall(name, arguments: arguments, validatingArguments: false)
        let presentation = CallPresentation()
        return try await Self.$presentation.withValue(presentation) {
            let result = try await call(resolved.name, resolved.arguments, admittedSurface: surface)
            guard !presentation.notices.isEmpty else { return result }
            return result.adding("content", .array((result["content"].array ?? []) + [
                .object(["type": .string("text"), "text": .string(presentation.notices.joined(separator: "\n"))])]))
        }
    }

    /// Executes a resolved name after admission to the fixed list or the discovery catalogue.
    private func call(
        _ name: String,
        _ arguments: JSONValue,
        admittedSurface surface: ToolSurface
    ) async throws -> JSONValue {
        if BatchMode.usesGestures, (["act", "select", "menu"] + ToolArguments.inputTools).contains(name),
           let supplied = arguments.object?["then"] {
            guard let following = supplied.array, following.count < BatchPolicy.maximumSteps,
                  var first = arguments.object else { throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.rows.v1")), cause: "invalid_arguments") }
            first.removeValue(forKey: "then")
            first.removeValue(forKey: "session")
            first["operation"] = .string(name)
            var batch: [String: JSONValue] = ["steps": .array([.object(first)] + following)]
            if let session = arguments.object?["session"] { batch["session"] = session }
            return try await BatchMode.$isExpandingGestures.withValue(true) {
                try await call("batch", .object(batch), surface: surface)
            }
        }
        callSequence += 1
        let sequence = callSequence
        guard let sink = taskStateSink else {
            return try await Self.$taskStateCall.withValue(nil) {
                try await runCall(name, arguments, surface: surface)
            }
        }
        let observation = TaskStateCall(tool: name)
        func emit(_ fact: TaskStateInput.Fact, kind: String) {
            sink(TaskStateInput(fact: fact, origin: .dispatcher, sequence: sequence, key: "c\(sequence).\(kind)"))
        }
        func emitFacts() {
            for (index, fact) in observation.facts.enumerated() {
                let kind: String
                if case .callFailed = fact { kind = "failed" } else { kind = "finished" }
                emit(fact, kind: kind + (index == 0 ? "" : ".\(index)"))
            }
        }
        do {
            let result = try await Self.$taskStateCall.withValue(observation) {
                try await runCall(name, arguments, surface: surface)
            }
            for (index, item) in observation.loaded.enumerated() { emit(.loaded(item), kind: "loaded.\(index)") }
            if observation.facts.isEmpty { observation.facts.append(.callFinished(tool: name, subject: nil, outcome: nil)) }
            emitFacts()
            return result
        } catch {
            emitFacts()
            emit(.callFailed(tool: name, reason: (error as? AutomationFailure)?.cause
                ?? String(reflecting: type(of: error))),
                kind: observation.facts.isEmpty ? "failed" : "failed.error")
            throw error
        }
    }

    private func runCall(_ name: String, _ arguments: JSONValue, surface: ToolSurface) async throws -> JSONValue {
        if name == "human_step" || (surface == .v1 && ["find", "call"].contains(name)) { throw unknownTool() }
        if name == "find", surface == .v2 {
            try Task.checkCancellation()
            if let contract = registry.contract(for: .init(rawValue: "find")) { try validate(arguments, contract: contract) }
            guard let query = arguments["query"].string,
                  Set(arguments.object?.keys.map { $0 } ?? []).isSubset(of: ["query", "limit"]) else { throw unknownTool() }
            let limit: Int
            if let value = arguments.object?["limit"] {
                guard case .number(let number) = value, number.isFinite, number.rounded() == number,
                      (3...5).contains(number) else { throw unknownTool() }
                limit = Int(number)
            } else { limit = 5 }
            let hits = await search?.search(query, limit: limit) ?? []
            try Task.checkCancellation()
            let found = hits.compactMap { hit in entries.first { $0.contract.id == hit.id } }
            let value: JSONValue = .object([
                ModelText.text(.init(rawValue: "catalogue.key.capabilities")): .array(found.map { entry in .object([
                    "name": .string(entry.contract.id.rawValue), "group": .string(entry.contract.group),
                    "description": .string(entry.contract.description), "inputSchema": entry.contract.inputSchema,
                    ModelText.text(.init(rawValue: "catalogue.key.strict")): .bool(true)]) }),
                ModelText.text(.init(rawValue: "catalogue.key.groups")): .string(ToolCatalogue.groupIndex(entries)),
                "message": .string(found.isEmpty ? ModelText.text(.init(rawValue: "catalogue.noSuitable")) : "")])
            try formatter.transcribe("→ find", arguments)
            try formatter.transcribe("← find", value)
            Self.taskStateCall?.loaded += found.map { .schema(capability: $0.contract.id.rawValue) }
            return MCPRouter.toolResult(value)
        }
        if let contract = registry.contract(for: .init(rawValue: name)) {
            guard permits(contract) || name == "open_session" else { throw unknownTool() }
            if registeredContract(name) != nil || (surface == .v2 && entries.contains { $0.contract.id == contract.id }) {
                try validate(arguments, contract: contract)
            }
        }
        let arguments = ToolArguments.admitted(arguments, surface: surface)
        if usesFixedList, name == "act", arguments["verb"].string == "triple_click" {
            throw AutomationFailure(ModelText.text(.init(rawValue: "catalogue.enum")), cause: "invalid_arguments")
        }
        let gesture = TaskCycleArm.current == .v2 && !["open_session", "close_session", "plan", "end", "ask_person", MemoryTaskTool.name].contains(name)
            && registry.effectClass(of: name, arguments: arguments) != .read
        var transition: StepTransition?
        if gesture {
            if let refusal = taskCycle.planFirstRefusal(for: name) { throw AutomationFailure(refusal, cause: "plan_required") }
            if let tool = AgentTool(rawValue: name) {
                let definition = callDefinitions(surface: surface).first { $0["name"].string == name }
                let properties = Set(definition?["inputSchema"]["properties"].object?.keys.map { $0 } ?? [])
                guard let fields = arguments.object, Set(fields.keys).isSubset(of: properties) else {
                    throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.allowed.v1")), cause: "invalid_arguments")
                }
                if tool.takesSession {
                    guard let id = session.id else { throw Self.noSession }
                    guard surface == .v2 || arguments["session"].string == id.uuidString else {
                        throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.id.v1")), cause: "invalid_arguments")
                    }
                }
                _ = try ToolArguments.callRequest(name, arguments)
                if name == "batch" {
                    guard let rows = arguments["steps"].array, (1...20).contains(rows.count) else {
                        throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.rows.v1")), cause: "invalid_arguments")
                    }
                    for row in rows {
                        _ = try Step(ToolArguments.requiredString(row, "operation"), row, inBatch: true)
                        if let id = try ToolArguments.step(in: row),
                           taskCycle.todo?.rows.contains(where: { $0.id == id && $0.status != .abandoned }) != true {
                            throw AutomationFailure(ModelText.text(.init(rawValue: "task_cycle.step_open.v2")), cause: "unknown_step")
                        }
                    }
                }
            }
            transition = try await taskCycle.step(to: ToolArguments.step(in: arguments), gesture: name)
            taskCycle.gesturesWithoutPlan += 1
        }
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
        output.mayHaveActed = false
        let scope = await scope(of: name, arguments, surface: surface)
        do {
            var result = try await CallScope.$current.withValue(scope) {
                let shown = producerSecrets.shownMinimization
                return try await ScreenExpectation.$valueIsReadable.withValue({ value in
                    value != ValueMinimization.marker && shown.minimize(text: value).1 == nil
                }) {
                    try await MemoryService.labelled("tool \(name)") { try await toolCall(name, arguments, surface: surface) }
                }
            }
            if let row = transition?.finished {
                let line = ModelText.render(.init(rawValue: "task_cycle.transition.v2"),
                    ["row": .rowID(row), "verdict": .rowVerdict(transition?.verdict ?? .unknown)])
                result = result.adding("content", .array((result["content"].array ?? []) + [
                    .object(["type": .string("text"), "text": .string(line)])]))
            }
            return result
        } catch {
            // The error reaches the model and its log: the producer's secrets and what the call withholds are
            // withheld from it too.
            let shown = ValueMinimization(secrets: producerSecrets.secrets, classified: scope.withheld, scrubsCredentials: false)
            guard !(error is CancellationError) else { throw error }
            let (kept, reason) = shown.minimize(text: String(describing: error))
            let failure: any Error = !shown.knowsNoText && reason != nil ? AutomationFailure(kept) : error
            if ResultFormatter.usesOutcomeV2, AgentTool(rawValue: name)?.requiresConfirmedStart == true {
                Self.taskStateCall?.facts.append(.callFailed(tool: name,
                    reason: (error as? AutomationFailure)?.cause ?? String(reflecting: type(of: error))))
                return formatter.thrown(error, tool: name, mayHaveActed: output.mayHaveActed, minimized: kept, surface: surface)
            }
            throw failure
        }
    }

    /// What a call withholds and binds before its first write (W1). A `type_text` or `insert_text`, or a batch's
    /// first step when it is one of them, is classified by the session on a fresh perception: an ordinary field's
    /// text is kept and its dispatch bound to that field; a secure field's text is withheld and becomes one of the
    /// producer's secrets; any other is withheld for this call only, as unclassified. A batch's later text steps
    /// come after an earlier step's effect, so they cannot be classified when the batch is planned: their texts are
    /// withheld in the plan. A text whose call names another session, or whose step the call will refuse, is
    /// withheld as unclassified too, since its transcript line comes before the refusal.
    private func scope(of name: String, _ arguments: JSONValue, surface: ToolSurface) async -> CallScope {
        var scope = CallScope()
        if name == "app_call" { return contentScope(of: arguments) }
        if let contract = registry.contract(for: .init(rawValue: name)), case .adapter(let app) = contract.origin {
            return contentScope(of: adapterArguments(contract.id.rawValue, app: app, arguments: arguments))
        }
        confidentialScope(of: name, arguments, in: &scope)
        guard ["type_text", "insert_text", "batch"].contains(name) else { return scope }
        let rows = name == "batch" ? (arguments["steps"].array ?? []) : [arguments]
        let current = session.id.map { surface == .v2 || arguments["session"].string == $0.uuidString } ?? false
        for (position, row) in rows.enumerated() {
            let operation = name == "batch" ? (row["operation"].string ?? "") : name
            guard let step = try? Step(operation, row, inBatch: name == "batch") else {
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

    private func toolCall(_ name: String, _ arguments: JSONValue, surface: ToolSurface) async throws -> JSONValue {
        if name == "read_guide", let guideProvider {
            try Task.checkCancellation()
            try formatter.transcribe("→ \(name)", arguments)
            let result = try await guideProvider.call(.init(rawValue: name), arguments: arguments,
                context: .init(sessionID: session.id))
            try Task.checkCancellation()
            try formatter.transcribe("← \(name)", result)
            let text = try result.string ?? String(decoding: JSONValue.canonicalEncoder().encode(result), as: UTF8.self)
            return MCPRouter.textResult(producerSecrets.withheld(text))
        }
        if TaskCycleArm.current == .v2 {
            if name == "plan" || name == "end" { return try await taskCycle.cycleCall(name, arguments) }
            if name == MemoryTaskTool.name { throw AutomationFailure(ModelText.text(.init(rawValue: "task_cycle.legacy_tool.v2")), cause: "unknown_tool") }
        } else if name == MemoryTaskTool.name { return try await taskCycle.call(arguments) }
        let before = sceneText.checkpoint()
        // A session that ended leaves no scene to compare the next one against.
        defer { if session.id == nil { sceneText.contextHolds(after: .newSession) } }
        do {
            return try await dispatch(name, arguments, surface: surface)
        } catch {
            // A failed call reaches the model without its scenes, so the baseline stays the one it read.
            sceneText.restore(before)
            let guidance = session.id == nil
                ? ModelText.text(.init(rawValue: "call_dispatcher.guidance.v1"))
                : ModelText.text(.init(rawValue: "call_dispatcher.guidance.v1.2"))
            try formatter.transcribe("← \(name) error: \(error). \(guidance)")
            throw error
        }
    }

    private func adapterArguments(_ name: String, app: String, arguments: JSONValue) -> JSONValue {
        var admitted = arguments
        if let contract = registry.contract(for: .init(rawValue: name)),
           consumesRoutingStep(contract), var fields = admitted.object {
            fields.removeValue(forKey: "step")
            admitted = .object(fields)
        }
        return .object(["app": .string(app), "verb": .string(String(name.dropFirst(app.count + 1))), "arguments": admitted])
    }

    /// Runs the call under its recorder, when the session has a memory. A call that may change the
    /// application or the Seat is confirmed in the archive, planned and started with its admitted
    /// arguments and its task attribution, before any effect: when the memory does not confirm it, or
    /// cannot represent it, the call is refused and nothing is done. A read-only call runs whatever the
    /// memory answers, and its answer says when it was not recorded. The engine reports to the recorder
    /// through `CallRecorder.current`; the call's end carries the result the tool answered, or its error,
    /// with the check the operation's oracle made. An end the memory cannot save suspends it: the answer
    /// says so, the effect is never repeated, and no further effect starts until the end is saved.
    private func dispatch(_ name: String, _ arguments: JSONValue, surface: ToolSurface,
                          reportedName: String? = nil) async throws -> JSONValue {
        if let contract = registry.contract(for: .init(rawValue: name)), case .adapter(let app) = contract.origin {
            return try await dispatch("app_call", adapterArguments(name, app: app, arguments: arguments),
                surface: surface, reportedName: name)
        }
        let shownName = reportedName ?? name
        let arguments = arguments == .null ? JSONValue.object([:]) : arguments
        if name == "triple_click", let contract = registry.contract(for: .init(rawValue: name)) {
            let claim = try claimDataWrites([], capability: contract)
            defer { withExtendedLifetime(claim) {} }
            if let refusal = try await uncertaintyRefusal([], capability: contract) {
                throw AutomationFailure(refusal, cause: "uncertainty_refusal")
            }
            guard let target = arguments["target"].string, session.id != nil else { throw Self.noSession }
            try formatter.transcribe("→ \(name)", arguments)
            let (result, notice) = try await recordCapability(contract, arguments: arguments) {
                let done = try await session.act(target: target, verb: .tripleClick,
                    section: arguments["section"].string, desiredState: nil)
                output.lastCheck = done.withStatedCheck.check
                return await outcome(surface: surface, done, refusal: refusalContext(tool: name, arguments: arguments))
            }
            return try finish(surface: surface, shownName, result, notice: notice)
        }
        if let contract = registeredContract(name) {
            let claim = try claimDataWrites([], capability: contract)
            defer { withExtendedLifetime(claim) {} }
            if let refusal = try await uncertaintyRefusal([], capability: contract) { throw AutomationFailure(refusal, cause: "uncertainty_refusal") }
            if let refusal = try await registeredValueRefusal(contract, arguments) { throw AutomationFailure(refusal, cause: "historical_value_refusal") }
            return try await answer(name, arguments, recorder: nil, surface: surface, reportedName: reportedName)
        }
        let request = try? ToolArguments.callRequest(name, arguments)
        guard let recorder = makeRecorder(sessionID: session.id) else {
            output.mayHaveActed = formatter.mayAct(
                name, arguments: arguments, request: request,
                definitions: callDefinitions(surface: surface), surface: surface)
            return try finish(surface: surface, shownName, try await answer(name, arguments, recorder: nil, surface: surface, reportedName: reportedName), notice: nil)
        }
        guard let request else {
            if AgentTool(rawValue: name)?.requiresConfirmedStart == true {
                // The call itself refuses such a request before any effect: let it say why, unrecorded.
                _ = try await answer(name, arguments, recorder: nil, surface: surface, reportedName: reportedName)
                throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.it.v1")))
            }
            return try finish(surface: surface, shownName, try await answer(name, arguments, recorder: nil, surface: surface, reportedName: reportedName),
                          notice: ModelText.text(.init(rawValue: "call_dispatcher.it.v1.2")))
        }
        // The contract refuses such a call before the memory is asked; it is said as what it is, nothing run or recorded.
        if request.tool.requiresConfirmedStart, request.tool.takesSession, session.id == nil { throw Self.noSession }
        // P2-06: an effect not known blocks its repeat and what depends on it, across restarts.
        let planned = request.tool == .batch
            ? (arguments["steps"].array ?? []).compactMap { try? Step(string($0, "operation"), $0, inBatch: true).callRequest } : [request]
        let claim = try claimDataWrites(planned)
        defer { withExtendedLifetime(claim) {} }
        if let refusal = try await uncertaintyRefusal(planned) { throw AutomationFailure(refusal, cause: "uncertainty_refusal") }
        if let refusal = await historicalValueRefusal(name, arguments) { throw AutomationFailure(refusal, cause: "historical_value_refusal") }
        let attribution = request.tool == .batch ? nil : taskCycle.openTask?.attribution
        if case .batch = request {} else {
            do {
                try await recorder.begin(request, app: application(of: request), attribution: attribution)
            } catch {
                await producerSecrets.collect(from: recorder)
                guard !request.tool.requiresConfirmedStart else { throw Self.unconfirmed(error) }
                output.mayHaveActed = formatter.mayAct(
                    name, arguments: arguments, request: request,
                    definitions: callDefinitions(surface: surface), surface: surface)
                let value = try await CallRecorder.$current.withValue(nil) {
                    try await self.answer(name, arguments, recorder: nil, surface: surface, reportedName: reportedName)
                }
                return try finish(surface: surface, shownName, value, notice: (ModelText.text(.init(rawValue: "call_dispatcher.value.v1"))
                    + "\(error)"
                    + ModelText.text(.init(rawValue: "call_dispatcher.value.v1.2"))))
            }
        }
        await recorder.holdPauseUntilAnswered()
        do {
            let result = try await finishRecordedCall(name, arguments, request: request, recorder: recorder, surface: surface, reportedName: reportedName)
            await recorder.answered()
            return result
        } catch {
            await recorder.answered()
            throw error
        }
    }

    /// Formats every answer or error before the caller closes the held pause in call order.
    private func finishRecordedCall(
        _ name: String,
        _ arguments: JSONValue,
        request: AgentCallRequest,
        recorder: CallRecorder,
        surface: ToolSurface,
        reportedName: String? = nil
    ) async throws -> JSONValue {
        let shownName = reportedName ?? name
        await producerSecrets.collect(from: recorder)
        let minimization = await recorder.admittedMinimization()
        do {
            output.mayHaveActed = formatter.mayAct(
                name, arguments: arguments, request: request,
                definitions: callDefinitions(surface: surface), surface: surface)
            let value = try await CallMinimization.$current.withValue(minimization) {
                try await CallRecorder.$current.withValue(recorder) {
                    try await self.answer(name, arguments, recorder: recorder, surface: surface, reportedName: reportedName)
                }
            }
            // The notice is read after the end, which may itself be saved only in part.
            let notice: String?
            do {
                try await recorder.end(.completed, result: output.lastResult, tool: request.tool, check: output.lastCheck,
                                       batchConclusion: output.batchConclusion)
                notice = await recorder.recordingGap.map { (ModelText.text(.init(rawValue: "call_dispatcher.notice.v1"))
                    + "\($0)"
                    + ModelText.text(.init(rawValue: "call_dispatcher.notice.v1.2"))) }
            } catch {
                notice = Self.suspended(error)
            }
            await producerSecrets.collect(from: recorder)
            if request.tool != .batch, TaskCycleArm.current == .v2,
               registry.effectClass(of: name, arguments: arguments) != .read,
               !["open_session", "close_session"].contains(name) {
                taskCycle.noteGesture(eventID: recorder.eventID, outcome: output.lastCheck?.verdict.rawValue ?? "unknown",
                    uncertain: output.lastCheck?.limits.contains(.deliveryUncertain) != false)
            }
            return try finish(surface: surface, shownName, value, notice: notice)
        } catch {
            let cancelled = error is CancellationError
            let notice: String?
            do {
                try await recorder.end(cancelled ? .cancelled : .failed,
                                       result: cancelled ? nil : .error(message: String(describing: error)),
                                       tool: request.tool, check: output.lastCheck,
                                       batchConclusion: output.batchConclusion)
                notice = await recorder.recordingGap.map { (ModelText.text(.init(rawValue: "call_dispatcher.notice.v1.3"))
                    + "\($0)"
                    + ModelText.text(.init(rawValue: "call_dispatcher.notice.v1.4"))) }
            } catch let failure {
                notice = Self.suspended(failure)
            }
            if request.tool != .batch, registry.effectClass(of: name, arguments: arguments) != .read,
               !["open_session", "close_session"].contains(name) {
                taskCycle.noteGesture(eventID: recorder.eventID, outcome: "unknown", uncertain: true)
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
    static let noSession = AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.noSession.v1"))
                                             + ModelText.text(.init(rawValue: "call_dispatcher.noSession.v1.2")), cause: "no_session")

    /// The refusal of a call whose start the memory did not confirm: nothing was done.
    private static func unconfirmed(_ error: any Error) -> AutomationFailure {
        AutomationFailure(
            (ModelText.text(.init(rawValue: "call_dispatcher.unconfirmed.v1"))
                + "\(error)"
                + ModelText.text(.init(rawValue: "call_dispatcher.unconfirmed.v1.2")))
                + ModelText.text(.init(rawValue: "call_dispatcher.unconfirmed.v1.3")), cause: "memory_unconfirmed"
        )
    }

    /// What the answer says when the end of a call that may have acted could not be saved.
    private static func suspended(_ error: any Error) -> String {
        (ModelText.text(.init(rawValue: "call_dispatcher.suspended.v1"))
            + "\(error)"
            + ModelText.text(.init(rawValue: "call_dispatcher.suspended.v1.2")))
            + ModelText.text(.init(rawValue: "call_dispatcher.suspended.v1.3"))
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
    private func claimDataWrites(
        _ requests: [AgentCallRequest],
        readOnly: Bool = false,
        capability: CapabilityContract? = nil
    ) throws -> AppClaims.Hold? {
        let registeredWrite = capability.map { $0.effect != .read } ?? false
        guard !readOnly, registeredWrite || requests.contains(where: gatesUncertainty),
              let directory = session.memoryDirectory else { return nil }
        let identity = try JSONEncoder().encode([producer.source.rawValue, producer.streamID])
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let claims = AppClaims(namespace: directory.appending(path: "effect-claims", directoryHint: .isDirectory))
        switch claims.acquire(key, owner: UUID()) {
            case .success(let hold): return hold
            case .failure:
                throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.hold.v1")))
        }
    }

    /// Why `request` may not run now (P2-06): it repeats a call of this producer whose effect is not known, or acts on the
    /// resource such a call reached, and no later fact resolved it. A read-only call, and `memory_task`, always run. The
    /// refusal holds across restarts, since it reads the archive; what resolves it is `memory_task reconcile`.
    private func uncertaintyRefusal(
        _ requests: [AgentCallRequest],
        capability: CapabilityContract? = nil
    ) async throws -> String? {
        // A call with an oracle of its own (an adapter's) is what the gate holds: a UI gesture's unverified effect is read on
        // the next observation of the same window, and a repeat there is the agent's reading of it.
        let registeredWrite = capability.map { $0.effect != .read } ?? false
        guard registeredWrite || requests.contains(where: gatesUncertainty),
              let directory = session.memoryDirectory else { return nil }
        let memory = MemoryService.shared(for: directory)
        let executor = try await MemoryExecutor.current(memory: memory, source: producer.source)
        if let executor { await MemoryExecutor.sweep(memory, folder: directory, current: executor) }
        // A pending call of this executor can still act; it must block a concurrent repeat too. Read errors fail closed.
        let unresolved = try await memory.unresolvedCalls(source: producer.source, streamID: producer.streamID,
                                                         excludingExecutor: nil).filter { gatesUncertainty($0.request) }
        // Registered writes have no saved resource identity yet, so unresolved effects block them conservatively.
        if registeredWrite, let call = unresolved.first {
            return ModelText.text(.init(rawValue: "capability.unresolvedPrefix"))
                + "\(call.eventID)"
                + ModelText.text(.init(rawValue: "capability.unresolvedSuffix"))
        }
        for call in unresolved {
            for request in requests where gatesUncertainty(request) {
                let repeats = call.isRepeated(by: request)
                if repeats {
                    return (ModelText.text(.init(rawValue: "call_dispatcher.repeats.v1"))
                        + "\(call.eventID)"
                        + ModelText.text(.init(rawValue: "call_dispatcher.repeats.v1.2"))
                        + "\(call.reason.rawValue)"
                        + ModelText.text(.init(rawValue: "call_dispatcher.repeats.v1.3")))
                        + ModelText.text(.init(rawValue: "call_dispatcher.repeats.v1.4"))
                }
                if call.isDepended(on: request) {
                    return (ModelText.text(.init(rawValue: "call_dispatcher.repeats.v1.5"))
                        + "\(call.eventID)"
                        + ModelText.text(.init(rawValue: "call_dispatcher.repeats.v1.6")))
                        + ModelText.text(.init(rawValue: "call_dispatcher.repeats.v1.7"))
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
        return (ModelText.text(.init(rawValue: "call_dispatcher.value.v1.3"))
            + "\(value)"
            + ModelText.text(.init(rawValue: "call_dispatcher.value.v1.4")))
            + ModelText.text(.init(rawValue: "call_dispatcher.value.v1.5"))
    }

    /// Refuses identifiers imported from earlier attempts before a registered write reaches its provider.
    private func registeredValueRefusal(_ contract: CapabilityContract, _ arguments: JSONValue) async throws -> String? {
        guard contract.effect != .read, let task = taskCycle.openTask,
              let directory = session.memoryDirectory else { return nil }
        let values = StructuredLeaves.fields(of: arguments).filter { $0.kind == .text || $0.kind == .number }
            .compactMap(\.text).filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        let found = try await MemoryService.shared(for: directory).historicalValues(values, attemptID: task.attemptID)
        guard let value = found.first else { return nil }
        return ModelText.text(.init(rawValue: "capability.historicalPrefix"))
            + value
            + ModelText.text(.init(rawValue: "capability.historicalSuffix"))
    }

    private static func batchStepFailure(_ error: any Error) -> String {
        if let failure = error as? AutomationFailure { return failure.description }
        return ModelText.text(.init(rawValue: "call_dispatcher.batch_failure.v2"))
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
            minimization: producerSecrets.recordMinimization,
            access      : taskCycle.memoryAccess
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

    /// Records provider execution without replacing a completed result or the provider's failure.
    private func callProvider(
        _ contract: CapabilityContract,
        arguments: JSONValue
    ) async throws -> (result: JSONValue, notice: String?) {
        guard case .registered(let family) = contract.origin, let provider = providers[family] else {
            preconditionFailure("Missing provider for registered capability: \(contract.id.rawValue)")
        }
        var admitted = arguments
        if consumesRoutingStep(contract), case .object(var fields) = admitted {
            fields.removeValue(forKey: "step")
            admitted = .object(fields)
        }
        let values = admitted
        return try await recordCapability(contract, arguments: values) {
            try await provider.call(contract.id, arguments: values,
                context: CapabilityCallContext(sessionID: self.session.id))
        }
    }

    private func capabilityFailureText(_ error: any Error) -> String {
        let kept = producerSecrets.recordMinimization.minimize(text: String(describing: error)).0
        return ModelText.render(.init(rawValue: "catalogue.detail"), ["detail": .minimized(kept)])
    }

    private func recordCapability(
        _ contract: CapabilityContract,
        arguments: JSONValue,
        perform: () async throws -> JSONValue
    ) async throws -> (result: JSONValue, notice: String?) {
        if case .notRecorded = contract.memory { return (try await perform(), nil) }
        output.lastCheck = nil
        let frame = CapabilityCallRecorder.CallFrame(
            context: ActionContext(source: producer.source, streamID: producer.streamID, traceID: producer.traceID,
                sessionID: session.id?.uuidString), attribution: taskCycle.openTask?.attribution,
            contract: contract, minimization: producerSecrets.recordMinimization)
        return try await CapabilityCallRecorder.$frame.withValue(frame) {
            var started = false
            var notice: String?
            do {
                try await recording?.began(contract.id, arguments: arguments)
                started = recording != nil
            } catch {
                if contract.effect != .read { throw Self.unconfirmed(error) }
                notice = ModelText.text(.init(rawValue: "call_dispatcher.it.v1.2"))
            }
            if recording == nil, contract.effect != .read, contract.memory == .capabilityStep {
                throw AutomationFailure(ModelText.text(.init(rawValue: "catalogue.recordingRequired")))
            }
            let result: JSONValue
            do { result = try await perform() }
            catch {
                if started {
                    do { try await recording?.ended(contract.id, result: nil, failure: capabilityFailureText(error), verified: nil) }
                    catch let failure {
                        let suspension = Self.suspended(AutomationFailure(capabilityFailureText(failure)))
                        throw AutomationFailure(capabilityFailureText(error) + " " + suspension)
                    }
                }
                throw error
            }
            if started {
                do {
                    let verified: Bool?
                    if let check = output.lastCheck {
                        verified = check.verdict == .passed ? true : check.verdict == .failed ? false : nil
                    } else if case .readBack = contract.verification { verified = result["verified"].bool }
                    else { verified = nil }
                    try await recording?.ended(contract.id, result: result, failure: nil, verified: verified)
                } catch {
                    notice = ModelText.text(.init(rawValue: "capability.recordingPrefix")) + capabilityFailureText(error)
                        + ModelText.text(.init(rawValue: "capability.completedSuffix"))
                }
            } else if notice == nil {
                notice = ModelText.text(.init(rawValue: "call_dispatcher.it.v1.2"))
            }
            if started, contract.effect != .read {
                let verdict = output.lastCheck?.verdict.rawValue ?? result["verified"].bool.map { $0 ? "passed" : "failed" } ?? "unknown"
                taskCycle.noteGesture(eventID: frame.context.eventID, outcome: verdict, uncertain: verdict == "unknown")
            }
            return (result, notice)
        }
    }

    private func answer(
        _ name: String,
        _ arguments: JSONValue,
        recorder: CallRecorder?,
        surface: ToolSurface,
        reportedName: String? = nil
    ) async throws -> JSONValue {
        let shownName = reportedName ?? name
        output.lastResult = nil
        output.batchConclusion = nil
        output.lastCheck  = nil
        output.transcriptOmits = []
        output.contentTexts    = []
        output.modelText       = nil
        let arguments = arguments == .null ? JSONValue.object([:]) : arguments
        guard let definition = callDefinitions(surface: surface).first(where: { $0["name"].string == name }),
              let values = arguments.object else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.values.v1")), cause: "invalid_arguments")
        }
        if let contract = registeredContract(name) {
            try formatter.transcribe("→ \(shownName)", arguments)
            if contract.takesSession {
                if surface == .v2, session.id == nil { throw Self.noSession }
                guard let id = session.id, surface == .v2 || arguments["session"].string == id.uuidString else {
                    throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.id.v1")),
                        cause: session.id == nil ? "no_session" : "invalid_arguments")
                }
            }
            let (result, notice) = try await callProvider(contract, arguments: arguments)
            let value = notice != nil && result.object == nil ? JSONValue.object(["result": result]) : result
            return try finish(surface: surface, name, value, notice: notice)
        }
        let schema = definition["inputSchema"]
        let allowed = Set(schema["properties"].object?.keys.map { $0 } ?? [])
        guard Set(values.keys).isSubset(of: allowed) else { throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.allowed.v1")), cause: "invalid_arguments") }
        for field in schema["required"].array ?? [] {
            guard let key = field.string, values[key] != nil else { throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.key.v1")), cause: "invalid_arguments") }
        }
        try formatter.transcribe("→ \(shownName)", arguments)
        let value: JSONValue
        if !["status", "windows", "apps", "open_session", "app_capabilities", "app_call"].contains(name) {
            if surface == .v2, session.id == nil { throw Self.noSession }
            guard let id = session.id, surface == .v2 || arguments["session"].string == id.uuidString else {
                throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.id.v1")),
                        cause: session.id == nil ? "no_session" : "invalid_arguments")
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
                                     "next": .string(("\(first.name)" + ModelText.text(.init(rawValue: "call_dispatcher.first.v1")))

                                                         + (ModelText.text(.init(rawValue: "answer.CallDispatcher.first.v1.fragment.0"))
                                                         + "\(first.bundleID)"
                                                         + ModelText.text(.init(rawValue: "answer.CallDispatcher.first.v1.fragment.2"))))])
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
                listing["more"] = .string(("\(found.count - shown.count)" + ModelText.text(.init(rawValue: "call_dispatcher.listing.v1"))))
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
                throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.verb.v1")))
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
            value = outcome.json.adding("evidence", ResultFormatter.evidence(output.lastCheck, kind: outcome.kind, surface: surface))
            output.lastResult = .outcome(outcome.kind, message: outcome.message)
        case "open_session":
            if values["named"] != nil, arguments["named"].bool == nil {
                throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.content.v1")))
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
                        sceneText.contextHolds(after: .personHadApp)
                        value = .object([
                            "opened": .bool(true), "session": .string(id.uuidString),
                            "note": .string(ModelText.text(.init(rawValue: "call_dispatcher.id.v1.2"))
                                + ModelText.text(.init(rawValue: "call_dispatcher.id.v1.3")))
                        ]).adding("routeNote", note.map(JSONValue.string))
                        output.lastResult = nil
                    }
            }
            if session.id != nil, let bundle = session.memoryApplication ?? sceneText.seen.last?.scene.bundleID, let guides {
                let app = resolveGuideApp(bundle)
                Self.presentation?.head = guides.head(for: app)
                Self.presentation?.index = guides.index(for: app)
                if Self.presentation?.head != nil { guides.noteDelivered(for: app, sections: []) }
            }
            if TaskCycleArm.current == .v2, session.id != nil {
                if !taskCycle.planGuardArmed { taskCycle.gesturesWithoutPlan = 0 }
                taskCycle.planGuardArmed = true
            }
        case "observe":
            if values["full"] != nil, arguments["full"].bool == nil {
                throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.id.v1.4")))
            }
            await noteDispatch()
            let scene = try await session.observe()
            value = await observation(scene, changesOnly: arguments["full"].bool != true)
            output.lastResult = await observed(by: recorder)
        case "menu":
            await noteDispatch()
            let refusal = refusalContext(tool: name, arguments: arguments)
            let done = try await session.menu(path: string(arguments, "path"))
            value = await outcome(surface: surface, done, refusal: refusal)
            output.lastResult = .outcome(done.kind, message: done.message)
            output.lastCheck  = done.withStatedCheck.check
        case "press":
            await noteDispatch()
            let refusal = refusalContext(tool: name, arguments: arguments)
            let done = try await session.press(button: string(arguments, "button"))
            value = await outcome(surface: surface, done, refusal: refusal)
            output.lastResult = .outcome(done.kind, message: done.message)
            output.lastCheck  = done.withStatedCheck.check
        case "collect_posts":
            guard case .collectPosts(let target, let maxScrolls, let seconds) = try ToolArguments.callRequest(name, arguments)
            else {
                throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.seconds.v1")))
            }
            await noteDispatch()
            let collected = try await session.collectPosts(
                PostCollectionRequest(target: target, maxScrolls: maxScrolls, seconds: Double(seconds)))
            value = ResultFormatter.collection(collected)
        case "act", "select", "type_text", "insert_text", "press_key", "scroll", "drag", "context_menu":
            let step = try Step(name, arguments)
            let refusal = refusalContext(tool: name, arguments: arguments)
            let done = try await ScreenExpectation.$current.withValue(ToolArguments.gestureExpectation(in: arguments)) { try await perform(step, dispatch: CallScope.current.dispatch(of: step.texts, at: 0)) }
            value = await outcome(surface: surface, done, refusal: refusal)
            output.lastResult = .outcome(done.kind, message: done.message)
            output.lastCheck  = done.withStatedCheck.check
        case "batch":
            if BatchMode.isEnabled {
                return try await runPolicyBatch(arguments, recorder: recorder, surface: surface)
            }
            guard let rows = arguments["steps"].array, (1...20).contains(rows.count) else {
                throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.rows.v1")))
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
                stepGaps.append((ModelText.text(.init(rawValue: "call_dispatcher.gap.v1"))
                    + "\(index + 1)"
                    + ModelText.text(.init(rawValue: "call_dispatcher.gap.v1.2"))
                    + "\(gap)"
                    + ModelText.text(.init(rawValue: "call_dispatcher.gap.v1.3"))))
            }
            for (index, step) in steps.enumerated() {
                if Task.isCancelled {
                    // The cancellation ends the call as before; the steps it leaves unrun are recorded as never
                    // run, as after a stop, so none stays planned in the memory.
                    for child in (children ?? []).dropFirst(started) { try? await child.skip() }
                    throw CancellationError()
                }
                let child = children?.indices.contains(index) == true ? children?[index] : nil
                var rowTransition: StepTransition?
                do {
                    if TaskCycleArm.current == .v2, let row = try ToolArguments.step(in: rows[index]) {
                        rowTransition = try await taskCycle.step(to: row, gesture: step.callRequest.tool.rawValue)
                    }
                } catch {
                    Self.taskStateCall?.facts.append(.callFailed(tool: name,
                        reason: (error as? AutomationFailure)?.cause ?? String(reflecting: type(of: error))))
                    complete = false
                    results.append(.object(["status": .string("error"), "message": .string(Self.batchStepFailure(error))]))
                    break
                }
                if let child {
                    do {
                        try await child.startStep()
                    } catch {
                        Self.taskStateCall?.facts.append(.callFailed(tool: name, reason: "memory_unconfirmed"))
                        complete = false
                        var failure: [String: JSONValue] = ["status": .string("error"),
                                                "message": .string(Self.unconfirmed(error).description),
                                                "guidance": .string(ModelText.text(.init(rawValue: "call_dispatcher.child.v1")))]
                        if ResultFormatter.usesOutcomeV2 { failure["_failure_cause"] = .string("memory_unconfirmed") }
                        results.append(.object(failure))
                        try formatter.transcribe("← batch step \(index + 1) not run: \(error)")
                        break
                    }
                }
                started += 1
                let refusal = refusalContext(tool: try string(rows[index], "operation"), arguments: rows[index])
                let result: ActOutcome
                let dispatch = CallScope.current.dispatch(of: step.texts, at: index)
                do {
                    let minimization = await child?.admittedMinimization() ?? CallMinimization.current
                    result = try await CallMinimization.$current.withValue(minimization) {
                        try await CallRecorder.$current.withValue(child) { try await self.perform(step, dispatch: dispatch) }
                    }
                }
                catch {
                    Self.taskStateCall?.facts.append(.callFailed(tool: name,
                        reason: (error as? AutomationFailure)?.cause ?? String(reflecting: type(of: error))))
                    do {
                        try await child?.end(
                            error is CancellationError ? .cancelled : .failed,
                            result: error is CancellationError ? nil : .error(message: String(describing: error)),
                            tool  : step.callRequest.tool
                        )
                    } catch let failure {
                        memoryNotice = Self.suspended(failure)
                    }
                    if let child { taskCycle.noteGesture(eventID: child.eventID, outcome: "unknown", uncertain: true) }
                    await noteGap(of: child, at: index)
                    let guidance = session.id == nil
                        ? ModelText.text(.init(rawValue: "call_dispatcher.guidance.v1.3"))
                        : ModelText.text(.init(rawValue: "call_dispatcher.guidance.v1.4"))
                    let failed: JSONValue = .object(["status": .string("error"), "message": .string(Self.batchStepFailure(error)),
                        "guidance": .string(guidance)])
                    results.append(failed)
                    try formatter.transcribe("← batch step \(index + 1) error: \(error)")
                    complete = false
                    break
                }
                var value = await outcome(surface: surface, result, refusal: refusal)
                if let row = rowTransition?.finished {
                    let line = ModelText.render(.init(rawValue: "task_cycle.transition.v2"),
                        ["row": .rowID(row), "verdict": .rowVerdict(rowTransition?.verdict ?? .unknown)])
                    value = value.adding("message", .string([value["message"].string, line].compactMap { $0 }.joined(separator: "\n")))
                }
                results.append(value)
                do {
                    try await child?.end(.completed, result: .outcome(result.kind, message: result.message),
                                         tool: step.callRequest.tool, check: result.withStatedCheck.check)
                } catch {
                    memoryNotice = Self.suspended(error)
                }
                await noteGap(of: child, at: index)
                if let child {
                    taskCycle.noteGesture(eventID: child.eventID, outcome: result.withStatedCheck.check?.verdict.rawValue ?? "unknown",
                        uncertain: result.withStatedCheck.check?.limits.contains(.deliveryUncertain) != false)
                    await producerSecrets.collect(from: child)
                }
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
            formatter.resetRefusals()
            var result: [String: JSONValue] = ["status": .string("closed"),
                                               "message": .string(ModelText.text(.init(rawValue: "call_dispatcher.result.v1")))]
            if let warning = session.closeWarning { result["warning"] = .string(warning) }
            value = .object(result)
            output.lastResult = .closed(message: ModelText.text(.init(rawValue: "call_dispatcher.warning.v1")))
        default: throw AutomationFailure((ModelText.text(.init(rawValue: "call_dispatcher.warning.v1.2")) + "\(name)"))
        }
        if name == "status", TaskCycleArm.current == .v2 {
            return value.adding("switches", .object(SwitchBoard.current.values.mapValues(JSONValue.string)))
                .adding("switches_invalid", .object(SwitchBoard.invalid.mapValues(JSONValue.string)))
        }
        return value
    }

    /// Runs the policy arm, retaining every typed result until its parent has concluded.
    private func runPolicyBatch(_ arguments: JSONValue, recorder: CallRecorder?, surface: ToolSurface) async throws -> JSONValue {
        func batchError(_ error: any Error) -> String {
            let kept = producerSecrets.shownMinimization.minimize(text: Self.batchStepFailure(error)).0
            return ModelText.text(.init(rawValue: "batch.error.v2")) + kept
        }
        guard let rows = arguments["steps"].array, (1...BatchPolicy.maximumSteps).contains(rows.count) else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.rows.v1")), cause: "invalid_arguments")
        }
        let steps = try rows.map { try Step(string($0, "operation"), $0, inBatch: true) }
        let facts = try zip(steps, rows).map { try $0.0.facts(expectation: ToolArguments.expectation(from: $0.1.object?["expect"])) }
        let began = ContinuousClock.now
        let deadline = began.advanced(by: BatchPolicy.timeCap)
        let bundleID = session.memoryApplication
        let children = recorder.map { parent in
            steps.indices.compactMap { makeRecorder(sessionID: session.id, parent: parent, position: $0) }
        } ?? []
        if let recorder, children.count == steps.count {
            do {
                try await recorder.begin(batch: zip(children, steps).map { ($0, $1.callRequest) },
                                         app: memoryApplication, attribution: taskCycle.openTask?.attribution)
            } catch { throw Self.unconfirmed(error) }
        }
        let entry: SceneSnapshot
        do { entry = try await session.observe() }
        catch {
            let reason: BatchStopReason = BatchPolicy.stopReason(for: error, deadlineReached: ContinuousClock.now >= deadline,
                personInControl: AutomationCallInterruption.current?.wasInterrupted == true)
            var notice: String?
            for child in children {
                do { try await child.skip() } catch { notice = Self.suspended(error) }
            }
            let notRun = Outcome(gesture: .notSent, effect: .notApplicable, recovery: .doNotRepeat)
            var lines = steps.indices.map { "\($0 + 1). \(notRun.row) — \(reason.rawValue)" }
            lines.append(ModelText.text(.init(rawValue: "batch.stopped.v2")) + reason.rawValue)
            if reason == .error { lines.append(batchError(error)) }
            output.modelText = lines.joined(separator: "\n")
            output.lastResult = .batch(stopped: true, attempted: 0, verified: 0)
            output.batchConclusion = .stopped(at: 0, reason: reason)
            var answer: [String: JSONValue] = ["status": .string("stopped"), "message": .string(lines.joined(separator: "\n")),
                "attemptedSteps": .number(0), "verifiedSteps": .number(0), "requested": .number(Double(steps.count))]
            if let notice { answer["memory"] = .string(notice) }
            return .object(answer)
        }
        let plan = BatchPolicy.BatchPlanFacts(steps: facts, bundleID: bundleID ?? entry.bundleID)
        var conclusion = BatchConclusion.ranToEnd
        var decision = BatchPolicy.validate(plan, entryScene: entry)
        var scene: SceneSnapshot? = entry
        var earlier: [Outcome] = []
        var lines: [String] = []
        var attempted = 0
        var memoryNotice: String?
        for index in steps.indices {
            if AutomationCallInterruption.current?.wasInterrupted == true { decision = .stop(.personInControl) }
            else if InterruptibleWait.current?.stopRequested == true || ContinuousClock.now >= deadline { decision = .stop(.timeCap) }
            if case .stop(let reason) = decision {
                conclusion = .stopped(at: index, reason: reason)
                break
            }
            if scene == nil {
                do { scene = try await session.observe() }
                catch {
                    let reason: BatchStopReason = BatchPolicy.stopReason(for: error, deadlineReached: ContinuousClock.now >= deadline,
                        personInControl: AutomationCallInterruption.current?.wasInterrupted == true)
                    conclusion = .stopped(at: index, reason: reason)
                    if reason == .error {
                        let notRun = Outcome(gesture: .notSent, effect: .notApplicable, recovery: .doNotRepeat)
                        lines.append("\(index + 1). \(notRun.row) — \(batchError(error))")
                    }
                    break
                }
            }
            guard let before = scene else { conclusion = .stopped(at: index, reason: .error); break }
            let target = BatchPolicy.resolveTarget(of: index, in: plan, entryScene: entry, scene: before)
            decision = BatchPolicy.beforeStep(index, of: plan, scene: before, target: target,
                commits: BatchPolicy.stepCommits(facts[index], target: target.element, scene: before),
                earlier: earlier, elapsed: began.duration(to: .now))
            if case .stop(let reason) = decision { conclusion = .stopped(at: index, reason: reason); break }
            var step = steps[index]
            if index > 0, let element = target.element { step = step.addressed(to: element) }
            if index > 0, case .input(.drag(let from, .target(let destination)), let section) = step {
                var destinationFacts = facts
                destinationFacts[index] = .init(kind: .drag, target: destination, section: facts[index].section)
                let destinationPlan = BatchPolicy.BatchPlanFacts(steps: destinationFacts, bundleID: plan.bundleID)
                let resolved = BatchPolicy.resolveTarget(of: index, in: destinationPlan, entryScene: entry, scene: before)
                switch resolved {
                case .found(let element): step = .input(.drag(from: from, to: .target(element.label)), section: section)
                case .ambiguous: conclusion = .stopped(at: index, reason: .ambiguous)
                case .missing, .notNeeded: conclusion = .stopped(at: index, reason: .targetMissing)
                }
                if case .stopped = conclusion { break }
            }
            let child = children.indices.contains(index) ? children[index] : nil
            do {
                if TaskCycleArm.current == .v2, let row = try ToolArguments.step(in: rows[index]) {
                    _ = try await taskCycle.step(to: row, gesture: step.callRequest.tool.rawValue)
                }
            } catch {
                conclusion = .stopped(at: index, reason: AutomationCallInterruption.current?.wasInterrupted == true ? .personInControl : .refused)
                break
            }
            if AutomationCallInterruption.current?.wasInterrupted == true {
                conclusion = .stopped(at: index, reason: .personInControl)
                break
            }
            do { try await child?.startStep() }
            catch {
                memoryNotice = Self.unconfirmed(error).description
                conclusion = .stopped(at: index, reason: AutomationCallInterruption.current?.wasInterrupted == true ? .personInControl : .error)
                break
            }
            attempted += 1
            let beforeWindow = session.observedWindowNumber
            do {
                let rawResult = try await BatchStepBoundary.perform(until: deadline) {
                    try await ScreenExpectation.$current.withValue(facts[index].expectation) {
                        let minimization = await child?.admittedMinimization() ?? CallMinimization.current
                        return try await CallMinimization.$current.withValue(minimization) {
                            try await CallRecorder.$current.withValue(child) {
                                var dispatch = CallScope.current.dispatch(of: step.texts, at: index)
                                if case .input(let input, let section) = step, !step.texts.isEmpty {
                                    switch await session.classify(input, section: section) {
                                    case .ordinary(let binding): dispatch = .bound(binding)
                                    case .secure, .unclassified: dispatch = .withheld
                                    }
                                }
                                if AutomationCallInterruption.current?.wasInterrupted == true {
                                    return ActOutcome(.refused, "person_in_control", notSent: .humanIntervention)
                                }
                                if InterruptibleWait.current?.stopRequested == true {
                                    return ActOutcome(.refused, "time_cap", notSent: .humanIntervention)
                                }
                                return try await perform(step, dispatch: dispatch)
                            }
                        }
                    }
                }
                let result = rawResult.withStatedCheck
                noteOutcome(result, tool: step.callRequest.tool.rawValue,
                            personInControl: result.notSent == .humanIntervention
                                && AutomationCallInterruption.current?.wasInterrupted == true)
                earlier.append(result.outcome)
                scene = result.scene
                lines.append("\(index + 1). \(result.outcome.row) — \(result.message.replacingOccurrences(of: "\n", with: " "))")
                do {
                    try await child?.end(.completed, result: .outcome(result.kind, message: result.message),
                                         tool: step.callRequest.tool, check: result.withStatedCheck.check)
                } catch { memoryNotice = Self.suspended(error) }
                if let child {
                    taskCycle.noteGesture(eventID: child.eventID, outcome: result.withStatedCheck.check?.verdict.rawValue ?? "unknown",
                                          uncertain: result.outcome.gesture == .uncertain)
                    await producerSecrets.collect(from: child)
                }
                let next = index + 1
                let nextPresent = scene.map {
                    BatchPolicy.resolveTarget(of: next, in: plan, entryScene: entry, scene: $0).isPresent
                } ?? false
                let announced: Bool
                if case .window? = facts[index].expectation { announced = true } else { announced = false }
                decision = BatchPolicy.afterStep(result.outcome,
                    expectedAbsent: BatchPolicy.expectedAbsent(facts[index], outcome: result.outcome, sceneBefore: before),
                    unexpectedSurface: beforeWindow != session.observedWindowNumber && !announced,
                    nextTargetPresent: nextPresent, isLastStep: next == steps.count)
                if AutomationCallInterruption.current?.wasInterrupted == true { decision = .stop(.personInControl) }
                else if ContinuousClock.now >= deadline || InterruptibleWait.current?.stopRequested == true
                    || result.notSent == .humanIntervention { decision = .stop(.timeCap) }
                if memoryNotice != nil { decision = .stop(.error) }
                if case .stop(let reason) = decision { conclusion = .stopped(at: index, reason: reason); break }
            } catch {
                let reason: BatchStopReason = BatchPolicy.stopReason(for: error, deadlineReached: ContinuousClock.now >= deadline,
                    personInControl: AutomationCallInterruption.current?.wasInterrupted == true)
                do {
                    if reason == .personInControl || reason == .timeCap {
                        let check = OperationCheck(condition: .none, method: .none, verdict: .unknown,
                            limits: [.deliveryUncertain, .noAfterScene], performed: .uncertain)
                        let stopped = ActOutcome(.actedUnverified, reason.rawValue, check: check)
                        noteOutcome(stopped, tool: step.callRequest.tool.rawValue)
                        earlier.append(stopped.outcome)
                        scene = nil
                        try await child?.end(.completed, result: .outcome(stopped.kind, message: stopped.message),
                                             tool: step.callRequest.tool, check: check)
                    } else {
                        Self.taskStateCall?.facts.append(.callFailed(tool: "batch",
                            reason: (error as? AutomationFailure)?.cause ?? String(reflecting: type(of: error))))
                        try await child?.end(.failed, result: .error(message: batchError(error)), tool: step.callRequest.tool)
                    }
                } catch { memoryNotice = Self.suspended(error) }
                let unknown = Outcome(gesture: .uncertain, effect: .unknown(.notReadable), recovery: .doNotRepeat)
                lines.append("\(index + 1). \(unknown.row) — \(reason.rawValue)")
                conclusion = .stopped(at: index, reason: reason)
                break
            }
        }
        for child in children.dropFirst(attempted) {
            do { try await child.skip() } catch { memoryNotice = memoryNotice ?? Self.suspended(error) }
        }
        let stopped: Bool
        if case .stopped(let position, let reason) = conclusion {
            stopped = true
            if position >= attempted, reason != .personInControl, reason != .timeCap {
                Self.taskStateCall?.facts.append(.callFailed(tool: "batch", reason: reason.rawValue))
            }
            let notRun = Outcome(gesture: .notSent, effect: .notApplicable, recovery: .doNotRepeat)
            for index in lines.count..<steps.count {
                let message = index == position ? reason.rawValue : AgentCallStatus.skipped.rawValue
                lines.append("\(index + 1). \(notRun.row) — \(message)")
            }
            lines.append(ModelText.text(.init(rawValue: "batch.stopped.v2")) + reason.rawValue)
        } else { stopped = false }
        let verified = earlier.filter { $0.effect == .confirmed }.count
        output.lastResult = .batch(stopped: stopped, attempted: attempted, verified: verified)
        output.batchConclusion = conclusion
        var answer: [String: JSONValue] = ["status": .string(stopped ? "stopped" : "completed"),
            "message": .string(lines.joined(separator: "\n")), "attemptedSteps": .number(Double(attempted)),
            "verifiedSteps": .number(Double(verified)), "requested": .number(Double(steps.count))]
        var text = lines.joined(separator: "\n")
        if let scene {
            let final = await observation(scene, changesOnly: true, nested: true)
            answer["observation"] = final
            if let sceneText = final["scene"].string ?? final["changes"].string { text += "\n" + sceneText }
        }
        output.modelText = text
        if let memoryNotice { answer["memory"] = .string(memoryNotice) }
        return .object(answer)
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
            throw AutomationFailure(ModelText.text(.init(rawValue: "call_dispatcher.adapters.v1")))
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
        case .menu(let path):
            return try await session.menu(path: path)
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
    /// True once the call reaches a path that can deliver input.
    var mayHaveActed = false

    /// The typed result of the call `answer` concluded last, for its record.
    var lastResult: AgentCallResult?
    var batchConclusion: BatchConclusion?

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

