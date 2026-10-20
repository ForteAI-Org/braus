//
//  CallRecorder.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
import SQLiteMemory

/// CallRecorder writes what one call did, saw and taught into the living memory, under the call's
/// context and, when the agent declared one, its task attempt.
///
/// The facts of the call are essential and confirmed (`MemoryService.confirm`): its start, with the
/// arguments as admitted and the task attribution, is committed before the call may act, and `begin`
/// throws when it is not, so the producer does not act; its end, written after the effect in one
/// transaction with the samples the engine perceived, the effect the call really had and the
/// verification the engine's oracle made (`OperationCheck`), suspends the memory when it cannot be
/// saved, and `end` throws then, so the producer reports it and acts no more. An observation's
/// sample is confirmed when it is taken, since the Brain learns from it before the scene is
/// enriched. What can be rebuilt from these facts (the scene associations, the Brain's learning) is
/// enqueued, never awaited.
///
/// Values the call may not keep are withheld before anything is written (`ValueMinimization`): from
/// its arguments, its result's message, its samples' labels and titles, its verification's texts and
/// what the Brain learns, with the gap declared. The texts withheld from the arguments are kept in
/// this recorder's memory only, to withhold them wherever else they appear (`withheldTexts`).
///
/// One recorder per call, and one per batch step. A call made outside the tools (a session's own
/// observation, the command line's `scene`) gets a recorder of its own and no call row: its event and
/// samples are written when they arrive. `current` is the recorder of the call the task is running,
/// set by the producer around the call so a session hands it to the engine without a parameter.
public actor CallRecorder: ActionObserving {

    /// The recorder of the call this task is performing, when a producer set one.
    @TaskLocal public static var current: CallRecorder?

    /// How long an observation waits for its own ingest before it enriches the scene from the Brain.
    public static let observationBudget: Duration = .milliseconds(50)

    nonisolated public let context: ActionContext
    nonisolated public let memory: MemoryService
    private let brain: BrainMemory
    private let requestedAt: Date
    private var minimization: ValueMinimization

    /// The application the call's event names, once the event is written: nil for a call made before
    /// any application (`status`, `windows`, `apps`, `open_session`).
    private var app: AppContextIdentity?
    private var eventWritten = false
    /// The call's row exists (begun, or planned with its batch): its samples wait for its end.
    private var callRecorded = false
    private var tool: AgentTool?
    private var attribution: TaskCallAttribution?
    private var startedNS: Int64?
    /// The effect the engine attributed, minimized, and why something of it was withheld.
    private var effect: SceneEffect?
    private var effectWithheld: WithholdingReason?
    private var attempt: ActionAttempt?
    private var target: OperationCheck.Target?
    /// The call's own samples, written with its end.
    private var samples: [CaptureSample] = []
    /// Samples of the call already in the archive (an observation's), which its verification may name.
    private var storedSamples: [CaptureSampleKey] = []
    /// Gaps found in what waits for the end.
    private var gaps: [ValueRedaction] = []
    /// The texts withheld from this call's arguments, in memory only.
    public private(set) var withheldTexts: [String] = []
    /// The content this call saw on a confidential surface or read from a confidential result (P1-06), in memory only:
    /// texts long enough to be searched for inside others (`confidentialFragments`) and whole values
    /// (`confidentialValues`). The producer keeps them for its later records, never for its answers.
    public private(set) var confidentialFragments: Set<String> = []
    public private(set) var confidentialValues: Set<String> = []
    /// What of the call's facts could not be saved, each said once, in order: shown to the agent as the
    /// record's gap after the call's end, which may add one.
    private var recordingGaps: [String] = []
    public var recordingGap: String? { recordingGaps.isEmpty ? nil : recordingGaps.joined(separator: "; ") }
    /// The `current` sample of the call's latest observation, once it is in the archive.
    public private(set) var lastObservation: CaptureSampleKey?
    /// The window the call last perceived (an observation, or an action's or a selector's capture after
    /// acting), so a scene the call returns is placed in that window's state.
    private var lastPerceived: PerceivedWindow?
    /// The observation events this call made for an application its own event does not name.
    private var observationEvents: [String: String] = [:]
    /// The route a routing session dispatched the call on, the last it reported, or the route of the session the call
    /// reached unrouted (M05).
    private var route: CallRoute?
    /// The adapter verb the call invoked (M05).
    private var adapterDispatch: AdapterDispatch?
    /// The rung the MacDriver's last gesture of this call took, as the session read it from the actuator (M05).
    private var rung: CallRung?
    /// The router's decision this call answered with its words (use, ask, or open with a note), as the tools handed it (M05).
    private var advice: CallRouteAdvice?
    /// What the action's record would teach the Brain's projection, kept until the call's end says
    /// whether its check verified the gesture: an effect the check did not verify teaches nothing.
    private var projectionCommand: BrainApplicationCommand?
    /// The leaves of an adapter's arguments and result, as offered, minimized at the end (P2-02).
    private var argumentLeaves: [StructuredField] = []
    private var resultLeaves: [StructuredField] = []
    private var dataContext: CallDataContext?
    private var profile: String?

    public init(memory: MemoryService, brain: BrainMemory, context: ActionContext,
                minimization: ValueMinimization = ValueMinimization()) {
        self.memory       = memory
        self.brain        = brain
        self.context      = context
        self.minimization = minimization
        self.requestedAt  = memory.clock.brainNow()
    }

    nonisolated public var eventID: String { context.eventID }

    // MARK: The call

    /// Confirms the call planned and started, with its arguments as admitted, its task attribution and
    /// the gaps of what was withheld from them, before the call acts. Throws `EssentialWriteFailure`
    /// when the archive did not confirm it: the call must not act then. A request the contract cannot
    /// represent is `refused` the same way, so nothing acts unrecorded.
    public func begin(
        _ request  : AgentCallRequest,
        app        : AppContextIdentity?,
        attribution: TaskCallAttribution? = nil
    ) async throws {
        let clock = memory.clock
        let (admitted, redactions) = admit(request)
        let event = context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
        var opening: OperationOpening
        do {
            opening = try OperationOpening(
                call       : try AgentCallRecord(event: event, request: admitted),
                startedAtMS: clock.calendarMS(),
                attribution: attribution,
                redactions : redactions
            )
            // P2-06: the process running the call is linked with its start.
            opening.executor = MemoryExecutor.current(for: memory.directory, source: context.source)?.record
        } catch {
            throw EssentialWriteFailure.refused(MemoryService.describe(error))
        }
        let started = opening
        try await memory.confirm(
            "call \(request.tool.rawValue) start",
            beforeEffect: request.tool.requiresConfirmedStart
        ) {
            _ = try await $0.facts.open(started)
        }
        self.app          = app
        self.tool         = request.tool
        self.attribution  = attribution
        eventWritten      = true
        callRecorded      = true
        startedNS         = clock.monotonicNS()
    }

    /// Confirms a batch started and its steps planned, before its first step. Each step's recorder is
    /// the one given with it, whose context is the batch's child at its position.
    public func begin(batch steps: [(recorder: CallRecorder, request: AgentCallRequest)], app: AppContextIdentity?,
                      attribution: TaskCallAttribution? = nil) async throws {
        let clock = memory.clock
        let event = context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
        var children: [AgentCallRecord] = []
        var redactions: [ValueRedaction] = []
        var opening: BatchOpening
        do {
            for step in steps {
                let child = step.recorder.context.event(
                    app         : app,
                    occurredAtMS: clock.calendarMS(),
                    monotonicNS : clock.monotonicNS()
                )
                let (admitted, gaps) = await step.recorder.admit(step.request)
                children.append(try AgentCallRecord(event: child, request: admitted))
                redactions += gaps
            }
            opening = try BatchOpening(
                batch      : try AgentCallRecord(event: event, request: .batch),
                steps      : children,
                startedAtMS: clock.calendarMS(),
                attribution: attribution,
                redactions : redactions
            )
            opening.executor = MemoryExecutor.current(for: memory.directory, source: context.source)?.record
        } catch {
            throw EssentialWriteFailure.refused(MemoryService.describe(error))
        }
        let batchOpening = opening
        try await memory.confirm("call batch start", beforeEffect: true) { _ = try await $0.facts.open(batch: batchOpening) }
        for (step, request) in zip(steps.map(\.recorder), steps.map(\.request)) {
            await step.planned(app: app, tool: request.tool, attribution: attribution)
        }
        self.app         = app
        self.tool        = .batch
        self.attribution = attribution
        eventWritten     = true
        callRecorded     = true
        startedNS        = clock.monotonicNS()
    }

    /// A batch step whose call the batch already recorded as planned: only its start is left.
    private func planned(app: AppContextIdentity?, tool: AgentTool, attribution: TaskCallAttribution?) {
        self.app         = app
        self.tool        = tool
        self.attribution = attribution
        eventWritten     = true
        callRecorded     = true
    }

    /// Confirms a planned step started, before it acts; throws when the archive did not confirm it.
    public func startStep() async throws {
        let clock = memory.clock
        let at    = clock.calendarMS()
        let eventID = context.eventID, attribution = self.attribution
        try await memory.confirm("step start", beforeEffect: true) {
            _ = try await $0.facts.start(step: eventID, atMS: at, attribution: attribution)
        }
        startedNS = clock.monotonicNS()
    }

    /// Records a planned step that never ran, after an earlier step's effect: suspends the memory and
    /// throws when it cannot be saved.
    public func skip() async throws {
        let end = AgentCallTransition(context.eventID, AgentCallProgress(.skipped, endedAtMS: memory.clock.calendarMS()))
        let conclusion = try OperationConclusion(end: end)
        try await memory.confirm("step skipped", afterEffect: true) { _ = try await $0.facts.conclude(conclusion) }
    }

    /// Notes the route a routing session dispatches this call on, before the dispatch and again for each later one:
    /// the last is the route the call ran on, written with its end (M05).
    public func dispatched(on route: CallRoute) {
        self.route = route
    }

    /// Notes the route of a session the call reaches without a routing session in front of it, at the call that
    /// reaches it: kept only when no routing session reported one, so a routing session's route and hand-back reason
    /// stay as it reported them (M05).
    public func dispatched(unrouted route: CallRoute.Route) {
        if self.route == nil { self.route = CallRoute(route) }
    }

    /// Notes the adapter verb the call invokes, right before the adapter runs (`AdapterDispatch`), written with the
    /// call's end (M05).
    public func dispatched(adapter dispatch: AdapterDispatch) {
        adapterDispatch = dispatch
    }


    /// Notes the rung the MacDriver's last gesture of this call took (`CallRung`), as the session read it from the
    /// actuator's own note of that gesture right after the call's gestures, written with the call's end under the
    /// call's minimization (M05). A later gesture of the same call replaces it: the row names the last gesture noted.
    public func dispatched(rung: CallRung) {
        self.rung = rung
    }

    /// The router's decision an `open_session` answered with its words (M05): use or ask instead of opening, or open
    /// with a note; written with the call's end, the address and the words minimized as every text of the call is.
    public func advised(_ advice: CallRouteAdvice) {
        self.advice = advice
    }

    /// Notes the leaves of an adapter's argument object (P2-02), written with the call's end, each
    /// minimized as every text of the call is; the archive decides which name an earlier call's result.
    public func noted(arguments leaves: [StructuredField]) {
        argumentLeaves = leaves
    }

    /// Notes the leaves of an adapter's result (P2-02), written with the call's end: what the call's
    /// minimization withholds (a confidential field among them) is kept as a withheld leaf with its reason.
    public func noted(results leaves: [StructuredField]) {
        resultLeaves = leaves
    }

    /// Notes the data the call reached (P2-05), written with its end; the account is kept only as a minimal identifier.
    public func noted(context: CallDataContext) {
        dataContext = context
    }

    /// Notes the profile the session's pages are in (P2-05), for the data context of a call that reached an app or a page.
    public func noted(profile: String?) {
        if let profile { self.profile = profile }
    }


    /// The leaves minimized as every text of the call is: a withheld text keeps its reason, never its value.
    private func admit(leaves: [StructuredField]) -> [StructuredField] {
        leaves.map { leaf in
            guard leaf.withheld == nil, let text = leaf.text else { return leaf }
            let (_, reason) = minimization.minimize(text: text)
            return reason.map(leaf.withholding) ?? leaf
        }
    }

    /// Writes the call's end in one transaction: completed with what its tool answered, or failed with
    /// its error, or cancelled; the samples it perceived; for an operation, what it really did and the
    /// check its oracle made. After a call that may have acted, a failure suspends the memory and
    /// throws: the caller reports it and acts no more until it is saved. A call never begun writes
    /// nothing.
    public func end(
        _ status: AgentCallStatus,
        result  : AgentCallResult?,
        tool    : AgentTool,
        check   : OperationCheck? = nil
    ) async throws {
        guard callRecorded else { return }
        let clock    = memory.clock
        let duration = startedNS.map { MemoryClock.durationMS(from: $0, to: clock.monotonicNS()) }
        let observed = status == .completed && tool.isBatchStep ? effect.map(ObservedEffect.init) : nil
        let (kept, resultGap) = admit(result)
        // A hand-back's reason is the driver's sentence: withheld as every text of the call is.
        let route = self.route.map {
            CallRoute($0.route, handoffReason: $0.handoffReason.map { minimization.minimize(text: $0).0 })
        }
        // The rung's words are the driver's sentences about the call's gestures: withheld as every text of the call is.
        let rungTaken = self.rung.map {
            CallRung(rung: $0.rung, how: minimization.minimize(text: $0.how).0,
                     skipped: $0.skipped.map { minimization.minimize(text: $0).0 })
        }
        // The advice's route address and words are texts of the call too: withheld as every text of the call is; the
        // decision is kept.
        let adviceTaken = self.advice.map {
            CallRouteAdvice(decision: $0.decision, route: $0.route.map { minimization.minimize(text: $0).0 },
                            message: minimization.minimize(text: $0.message).0)
        }
        let end = AgentCallTransition(context.eventID, AgentCallProgress(
            status, result: kept, endedAtMS: clock.calendarMS(), durationMS: duration, observedEffect: observed
        ))
        var redactions = gaps + resultGap
        if let effectWithheld, observed != nil {
            redactions.append(ValueRedaction(
                eventID : context.eventID,
                location: .observedEffect,
                reason  : effectWithheld
            ))
        }
        var operationEffect: OperationEffect?
        if tool.hasOwnOracle {
            let (fact, targetGaps) = try effectFact(check: check, result: result)
            operationEffect = fact
            redactions += targetGaps
        }
        var verifications: [OperationVerification] = []
        if tool.hasOwnOracle, let check {
            let (admittedCheck, checkGaps) = admit(check)
            redactions += checkGaps
            let sampleKeys = storedSamples + samples.map(\.key)
            let event = context.verificationEvent(
                eventID: OperationVerification.eventID(call: context.eventID, condition: check.condition), app: app,
                occurredAtMS: clock.calendarMS()
            )
            verifications.append(try OperationVerification(
                event      : event,
                callEventID: context.eventID,
                check      : admittedCheck,
                samples    : sampleKeys
            ))
        }
        let arguments = admit(leaves: argumentLeaves).map { CallArgumentField(field: $0) }
        // A call that reached an app or a page names its service, route and profile (P2-05); its account stays unknown.
        if dataContext == nil, tool.takesSession || tool == .openSession, let app, let route = route?.route {
            let reached: CallDataContext.Route = switch route {
                case .native : .native
                case .desktop: .desktop
                case .web    : .web
            }
            dataContext = try? CallDataContext(service: app.bundleID, route: reached, profile: profile, accountSource: .unknown)
        }
        let results = admit(leaves: resultLeaves)
        let conclusion = try OperationConclusion(end: end, samples: samples, effect: operationEffect,
                                                 verifications: verifications, redactions: redactions, route: route,
                                                 adapterDispatch: adapterDispatch,
                                                 rung: rungTaken, advice: adviceTaken, argumentFields: arguments,
                                                 resultFields: results, dataContext: dataContext)
        // The least the end is saved as when the archive refuses the whole: its state and result, with
        // the parts it leaves out declared durably in the same transaction, and why.
        var omitted: [OperationRecordingGap.Part] = []
        if !samples.isEmpty { omitted.append(.samples) }
        if operationEffect != nil { omitted.append(.effect) }
        if !verifications.isEmpty { omitted.append(.verification) }
        let callID = context.eventID, minimization = self.minimization, omittedParts = omitted
        let invoked = adapterDispatch, noted = rungTaken, advised = adviceTaken
        let reached = dataContext
        let least: @Sendable (MemoryRepositories, EssentialWriteFailure) async throws -> Void = {
            repositories, refusal in
            let reason: OperationRecordingGap.Reason = switch refusal {
                case .conflict: .conflict
                default       : .refused
            }
            let detail  = minimization.minimize(text: refusal.description).0
            let unsaved = try omittedParts.map {
                try OperationRecordingGap(callEventID: callID, part: $0, reason: reason, detail: detail)
            }
            _ = try await repositories.facts.conclude(
                try OperationConclusion(end: end, redactions: resultGap, unsaved: unsaved, route: route,
                                        adapterDispatch: invoked, rung: noted, advice: advised,
                                        dataContext: reached)
            )
        }
        let saved = try await memory.confirm(
            "call \(tool.rawValue) end",
            afterEffect: tool.requiresConfirmedStart,
            fallback   : least
        ) {
            _ = try await $0.facts.conclude(conclusion)
        }
        if case .least(let refusal) = saved {
            let parts = omitted.map(\.rawValue)
            let what  = parts.isEmpty ? "the gaps it declared" : "its " + parts.joined(separator: ", ")
            recordingGaps.append("the call's end was saved without \(what), which the archive refused "
                + "(\(minimization.minimize(text: refusal.description).0)); the call is kept as incomplete evidence")
            samples = []
        }
        await associate(samples.map(\.key))
        samples = []
        gaps    = []
        await learn(tool: tool, check: saved == .whole ? check : nil)
    }

    /// What the call's facts teach the Brain, derived after they are saved and queued behind the scene
    /// associations its relation reads: the projection's transition only from an effect the check
    /// verified as the requested gesture's, and the relations from every operation, which say why when
    /// they learn nothing.
    private func learn(tool: AgentTool, check: OperationCheck?) async {
        if let command = projectionCommand, let check, check.condition == .structuralEffect, check.verdict == .passed,
           check.performed == .requested, !check.limits.contains(.deliveryUncertain), !check.limits.contains(.unattributed) {
            await memory.enqueue("brain record") { repositories in
                _ = try await repositories.applications.apply(command)
            }
        }
        projectionCommand = nil
        guard tool.isOperation else { return }
        let callID = context.eventID, nowMS = memory.clock.brainMS()
        let memory = self.memory
        await memory.enqueue("brain relation") { repositories in
            let evaluation = try await repositories.relations.apply(callEventID: callID, at: nowMS)
            // A call whose sample is not placed yet is evaluated again once it is, by the recovery.
            if evaluation.exclusion == .awaitingState { await memory.scheduleRelationRecovery() }
        }
    }

    // MARK: ActionObserving

    /// An action's record: its perceptions as the `before` and `after` samples, written with the call's
    /// end, and what it would teach the Brain's projection, an effect on an element, applied at the end
    /// only when the call's check verified that effect (`end`).
    public func record(_ record: ActionRecord) async {
        let controls = noteConfidential([record.before, record.after], bundleID: record.bundleID)
        let contentTarget = controls != nil && ConfidentialSurfaces.isContent(record.element)
        if contentTarget { withholdConfidential(wholes: [record.element.label]) }
        keep(effect: record.effect, controls: controls)
        attempt = record.attempt
        if let after = record.after { lastPerceived = after }
        target  = OperationCheck.Target(record.element)
        await keep([(record.before, .before), (record.after, .after)], bundleID: record.bundleID)
        // An effect with a withheld value teaches nothing: its transition would predict the marker. Nor does an action
        // on a confidential surface's content: its target is the person's, not the application's.
        guard eventWritten, record.effect != nil, effectWithheld == nil, !contentTarget else { return }
        projectionCommand = try? BrainApplicationCommand.record(admit(record), eventID: context.eventID, requestedAt: requestedAt)
    }

    /// An input's record: its perceptions as the `before`, `menu` and `after` samples, written with the
    /// call's end. An input teaches the Brain nothing.
    public func record(_ input: InputRecord) async {
        let controls = noteConfidential([input.before, input.menu, input.after], bundleID: input.bundleID)
        if controls != nil, let element = input.target, ConfidentialSurfaces.isContent(element) {
            withholdConfidential(wholes: [element.label])
        }
        keep(effect: input.effect, controls: controls)
        attempt = input.attempt
        target  = input.target.map(OperationCheck.Target.init)
        await keep([(input.before, .before), (input.menu, .menu), (input.after, .after)], bundleID: input.bundleID)
    }

    /// Keeps the effect the engine attributed with its titles and labels minimized: on a confidential surface only the
    /// labels of the application's own controls (`controls`) are kept.
    private func keep(effect observed: SceneEffect?, controls: Set<String>? = nil) {
        guard let observed else {
            effect = nil
            return
        }
        let (kept, reason) = minimization.minimize(effect: observed, confidentialControls: controls)
        effect         = kept
        effectWithheld = reason
    }

    // MARK: Confidential surfaces

    /// Notes the scenes a call perceived on a confidential surface (P1-06): their content is withheld from every record
    /// of this call. Answers the labels of the application's own controls in them, which an effect may name; nil when
    /// none of them is a confidential surface's.
    private func noteConfidential(_ windows: [PerceivedWindow?], bundleID: String) -> Set<String>? {
        var controls: Set<String>?
        for case let window? in windows where ConfidentialSurfaces.surface(of: window.scene.bundleID) != nil {
            noteConfidential(window.scene)
            controls = (controls ?? []).union(ConfidentialSurfaces.controlLabels(of: window.scene))
        }
        if controls == nil, ConfidentialSurfaces.surface(of: bundleID) != nil { controls = [] }
        return controls
    }

    /// Withholds a confidential scene's content from this call's records: its long texts wherever they appear, every
    /// content label and value, and the title, whole. Answers the scene's surface, nil when it is no confidential one.
    @discardableResult
    private func noteConfidential(_ scene: SceneSnapshot) -> ConfidentialSurface? {
        guard let surface = ConfidentialSurfaces.surface(of: scene.bundleID) else { return nil }
        let content = scene.elements.filter(ConfidentialSurfaces.isContent)
        withholdConfidential(fragments: ConfidentialSurfaces.contentTexts(of: scene),
                             wholes: content.map(\.label) + scene.elements.compactMap(\.value)
                                 + (ConfidentialSurfaces.contentTitle(of: scene).map { [$0] } ?? []))
        return surface
    }

    /// Withholds confidential content (P1-06) from every later record of this call, as `confidential_content`:
    /// `fragments` wherever they appear, `wholes` where a whole text is one of them. A result's confidential fields
    public func withholdConfidential(fragments: [String] = [], wholes: [String] = []) {
        let fragments = fragments.filter { $0.count >= ConfidentialSurfaces.shortestTrackedText && $0 != ValueMinimization.marker }
        let wholes = wholes.filter { !$0.isEmpty && $0 != ValueMinimization.marker }
        guard !fragments.isEmpty || !wholes.isEmpty else { return }
        minimization = minimization.adding(.confidentialContent, fragments: fragments, wholes: wholes)
        confidentialFragments.formUnion(fragments)
        confidentialValues.formUnion(wholes)
    }

    // MARK: Observations

    /// An observation: the window as the `current` sample, confirmed now, ingested into the Brain under
    /// it, and the scene enriched from the Brain, which is what the caller shows. When the call's event
    /// names no application, or another one (an `open_session`), the sample belongs to an observation
    /// event of the scene's application whose origin is this call. A sample the archive did not
    /// confirm leaves `lastObservation` nil, the record's gap; after an effect it suspends the memory.
    public func observe(_ window: PerceivedWindow) async -> SceneSnapshot {
        let scene    = window.scene
        let identity = AppContextIdentity(bundleID: scene.bundleID)
        let eventID: String?
        if eventWritten, app?.bundleID == scene.bundleID {
            eventID = context.eventID
        } else if !eventWritten {
            eventID = await ensureEvent(app: identity) ? context.eventID : nil
        } else {
            eventID = await observationEvent(for: identity)
        }
        lastPerceived = window
        let surface = noteConfidential(scene)
        guard let eventID else { return await shown(scene, window: window) }
        let key = CaptureSampleKey(eventID: eventID, phase: .current)
        let (sample, sampleGaps) = minimization.minimize(
            sample: CaptureSample(key: key, of: window, sessionRevision: nil), confidential: surface
        )
        guard (try? sample.validate()) != nil else {
            recordingGaps.append("the observation's sample was refused by the contract and not kept")
            lastObservation = nil
            return await shown(scene, window: window)
        }
        do {
            try await memory.confirm("sample current", afterEffect: tool?.requiresConfirmedStart == true) {
                _ = try await $0.facts.record(samples: [sample], redactions: sampleGaps)
            }
        } catch {
            recordingGaps.append("the observation was not saved: \(error)")
            lastObservation = nil
            return await shown(scene, window: window)
        }
        lastObservation = key
        storedSamples.append(key)
        await associate([key])
        if let command = try? BrainApplicationCommand.observe(
            minimization.minimize(scene: scene, confidential: surface),
            sample     : key,
            requestedAt: requestedAt,
            // P2-07: only a complete capture of a window ages what it does not show; a partial one attests presences.
            coverage   : BrainObservationCoverage(capture: window.capture, surface: window.surface, route: route?.route)
        ) {
            await memory.enqueue("brain observe") { repositories in
                _ = try await repositories.applications.apply(command)
            }
        }
        await memory.flush(within: Self.observationBudget)
        return await shown(scene, window: window)
    }

    /// The scene enriched from the Brain, for a result that carries a scene the call did not observe: in
    /// the state of the window the call last perceived when the scene is that window's (its token says
    /// so), named only otherwise, since a scene without its capture cannot be placed in a state.
    public func enrich(_ scene: SceneSnapshot) async -> SceneSnapshot {
        if let window = lastPerceived, window.scene.token == scene.token, window.scene.bundleID == scene.bundleID {
            return await shown(scene, window: window)
        }
        return await shown(scene)
    }

    /// The scene the caller shows: enriched from the Brain, or as perceived while a measure turns the Brain off
    /// (`MeasureAblation`), what it learns unchanged.
    private func shown(_ scene: SceneSnapshot, window: PerceivedWindow? = nil) async -> SceneSnapshot {
        guard !MeasureAblation.active.contains(.brain) else { return scene }
        if let window { return await brain.enrich(scene, window: window) }
        return await brain.enrich(scene)
    }

    /// A selection's or a contextual menu's perceptions, as its selector read them, written with the
    /// call's end. A selection attributes no scene effect and teaches the Brain nothing.
    public func record(before: PerceivedWindow?, menu: PerceivedWindow?, after: PerceivedWindow?, bundleID: String,
                       target: SceneElement? = nil) async {
        if noteConfidential([before, menu, after], bundleID: bundleID) != nil, let target,
           ConfidentialSurfaces.isContent(target) {
            withholdConfidential(wholes: [target.label])
        }
        if let target { self.target = OperationCheck.Target(target) }
        if let after { lastPerceived = after }
        await keep([(before, .before), (menu, .menu), (after, .after)], bundleID: bundleID)
    }

    // MARK: Events and samples

    /// Keeps perceptions as the call's samples: with the call's end when the call is recorded, or at
    /// once under an event of its own for a call made outside the tools.
    private func keep(_ windows: [(PerceivedWindow?, CapturePhase)], bundleID: String) async {
        var kept: [CaptureSample] = []
        var keptGaps: [ValueRedaction] = []
        let eventID: String
        if callRecorded {
            eventID = context.eventID
        } else {
            guard await ensureEvent(app: AppContextIdentity(bundleID: bundleID)) else { return }
            eventID = context.eventID
        }
        // Every confidential scene is noted before any sample is minimized: one's content may be another's label.
        for case let (window?, _) in windows { noteConfidential(window.scene) }
        for case let (window?, phase) in windows {
            let key = CaptureSampleKey(eventID: eventID, phase: phase)
            guard !samples.contains(where: { $0.key == key }), !storedSamples.contains(key) else { continue }
            let (sample, sampleGaps) = minimization.minimize(
                sample: CaptureSample(key: key, of: window, sessionRevision: nil),
                confidential: ConfidentialSurfaces.surface(of: window.scene.bundleID)
            )
            // A sample the contract refuses is left out, said as a gap: it never holds up the call's end.
            guard (try? sample.validate()) != nil else {
                recordingGaps.append("a \(phase.rawValue) sample the contract refuses was not kept")
                continue
            }
            kept.append(sample)
            keptGaps += sampleGaps
        }
        if callRecorded {
            samples += kept
            gaps    += keptGaps
            return
        }
        let written = kept, writtenGaps = keptGaps
        do {
            try await memory.confirm("samples", afterEffect: true) {
                _ = try await $0.facts.record(samples: written, redactions: writtenGaps)
            }
            storedSamples += written.map(\.key)
            await associate(written.map(\.key))
        } catch {
            recordingGaps.append("the samples were not saved: \(error)")
        }
    }

    /// Writes the call's event as an action of `app` when no call recorded it: a session's own
    /// observation, the command line's `scene`. False when the archive did not confirm it.
    private func ensureEvent(app: AppContextIdentity) async -> Bool {
        guard !eventWritten else { return true }
        let clock = memory.clock
        let event = context.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS())
        do {
            try await memory.confirm("event") { _ = try await $0.captures.record(event) }
        } catch {
            recordingGaps.append("the event was not saved: \(error)")
            return false
        }
        self.app     = app
        eventWritten = true
        return true
    }

    /// The observation event of an application this call's own event does not name, made once.
    private func observationEvent(for app: AppContextIdentity) async -> String? {
        if let known = observationEvents[app.bundleID] { return known }
        let derived = context.another(sessionID: context.sessionID)
        let clock   = memory.clock
        let event   = derived.event(app: app, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS(),
                                    kind: .observation)
        do {
            try await memory.confirm("observation event", afterEffect: tool?.requiresConfirmedStart == true) {
                _ = try await $0.captures.record(event)
            }
        } catch {
            recordingGaps.append("the observation event was not saved: \(error)")
            return nil
        }
        observationEvents[app.bundleID] = derived.eventID
        return derived.eventID
    }

    /// Offers the scene associations of samples now in the archive; a menu is kept but never associated.
    private func associate(_ keys: [CaptureSampleKey]) async {
        let nowMS = memory.clock.brainMS()
        for key in keys where key.phase.isAssociable {
            await memory.enqueue("scene \(key.phase.rawValue)") { _ = try await $0.scenes.associate(key, at: nowMS) }
        }
    }

    // MARK: Admission

    /// The request with what may not be kept withheld, and the gaps; the withheld texts are kept in
    /// memory to withhold them wherever else they appear in this call. A text withheld because the call
    /// could not attest its target (`unclassifiedTarget`) is already in this call's minimization and stays
    /// out of `withheldTexts`, which the tools make the producer's secrets: it is withheld for this call only.
    func admit(_ request: AgentCallRequest) -> (AgentCallRequest, [ValueRedaction]) {
        let (admitted, redactions) = minimization.minimize(request, eventID: context.eventID)
        guard !redactions.isEmpty else { return (admitted, []) }
        var original: [String: String] = [:]
        for argument in request.arguments {
            if case .text(let text) = argument.value { original["\(argument.name)#\(argument.position)"] = text }
        }
        for redaction in redactions {
            // Confidential content is the call's, like an unclassified target's text: never one of the producer's secrets,
            // which its answers would withhold from the model.
            guard case .argument(let name, let position) = redaction.location,
                  redaction.reason != .unclassifiedTarget, redaction.reason != .confidentialContent,
                  let text = original["\(name)#\(position)"],
                  text != ValueMinimization.marker else { continue }
            // A withheld text is searched for whole elsewhere, never by the parts a rule matched in it.
            if !withheldTexts.contains(text) { withheldTexts.append(text) }
        }
        minimization = minimization.adding(secrets: withheldTexts)
        return (admitted, redactions)
    }

    private func admit(_ result: AgentCallResult?) -> (AgentCallResult?, [ValueRedaction]) {
        minimization.minimize(result: result, eventID: context.eventID)
    }

    private func admit(_ check: OperationCheck) -> (OperationCheck, [ValueRedaction]) {
        var gaps: [ValueRedaction] = []
        func scrub(_ text: String?, _ location: ValueRedaction.Location) -> String? {
            guard let text else { return nil }
            let (_, reason) = minimization.minimize(text: text)
            guard let reason else { return text }
            gaps.append(ValueRedaction(eventID: context.eventID, location: location, reason: reason))
            return nil
        }
        let expected = scrub(check.expected, .verificationExpected(check.condition))
        let observed = scrub(check.observed, .verificationObserved(check.condition))
        var target   = check.target
        if let current = target {
            let (kept, targetGaps) = minimization.minimize(target: current, eventID: context.eventID)
            target = kept
            gaps  += targetGaps
        }
        // The effect the check judged had a value withheld: its evidence is kept in part.
        if let effectWithheld, effect != nil {
            gaps.append(ValueRedaction(eventID: context.eventID, location: .observedEffect, reason: effectWithheld))
        }
        let limits = gaps.isEmpty || check.limits.contains(.valueWithheld)
            ? check.limits
            : check.limits + [.valueWithheld]
        return (OperationCheck(condition: check.condition, method: check.method, methodVersion: check.methodVersion,
                               verdict: check.verdict, expected: expected, observed: observed, limits: limits,
                               performed: check.performed, substitute: check.substitute, target: target), gaps)
    }

    /// The record with its element's texts and identity minimized and the effect kept, for what the
    /// Brain learns; called only for an effect nothing was withheld from.
    private func admit(_ record: ActionRecord) -> ActionRecord {
        let element = minimization.minimize(element: record.element).0
        return ActionRecord(bundleID: record.bundleID, element: element, verb: record.verb, effect: effect,
                            windowTitleAfter: record.windowTitleAfter.map { minimization.minimize(text: $0).0 },
                            before: nil, after: nil, attempt: record.attempt)
    }

    /// What an operation really did: the check's account when its path reported one, else what the
    /// engine's record says of the gesture, else unknown; and the target, minimized.
    private func effectFact(
        check : OperationCheck?,
        result: AgentCallResult?
    ) throws -> (OperationEffect, [ValueRedaction]) {
        var performed: OperationCheck.Performed
        var reason: String?
        switch (check?.performed, attempt) {
            case (let stated?, _)              : performed = stated
            case (nil, .delivered?)            : performed = .requested
            case (nil, .notAttempted(let why)?): performed = .none; reason = why
            case (nil, .deliveryFailed?)       : performed = .uncertain
            case (nil, nil)                    : performed = .uncertain
        }
        if performed == .none, reason == nil {
            if case .notAttempted(let why)? = attempt { reason = why }
            else if case .outcome(let kind, _)? = result { reason = kind.rawValue }
        }
        if performed != .none { reason = nil }
        var fact = check?.target ?? target
        var gaps: [ValueRedaction] = []
        if let current = fact {
            let (kept, targetGaps) = minimization.minimize(target: current, eventID: context.eventID)
            fact = kept
            gaps = targetGaps
        }
        let effect = try OperationEffect(callEventID: context.eventID, performed: performed,
                                         substitute: performed == .substitute ? (check?.substitute ?? "unknown") : nil,
                                         notSentReason: reason, target: fact, checked: check != nil)
        return (effect, gaps)
    }
}

extension ActionContext {

    /// The event of a verification of this context's call: its own identity, the call's producer,
    /// trace and session, no parent.
    nonisolated func verificationEvent(
        eventID     : String,
        app         : AppContextIdentity?,
        occurredAtMS: Int64
    ) -> MemoryEventRecord {
        MemoryEventRecord(eventID: eventID, source: source, streamID: streamID, traceID: traceID, sessionID: sessionID,
                          kind: .verification, app: app, occurredAtMS: occurredAtMS)
    }
}
