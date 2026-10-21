//
//  MockTeam.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import ChatCore
import Foundation
import ModelTransports
import Observation

/// MockTeam is the part of `TeamModel` that the app's own components read in the house, on mock
/// values and never the engine: each worker's provider, model and effort, its usage and context,
/// its last turn and its Chrome window, and every provider's connection.
///
/// A worker of the sample house starts from a fixed history (`histories`); a worker it does not
/// know has recorded no turn, as a new one has not, and starts on the provider the app would give
/// it. A worker answers while it is busy or waits for the person, and then its model and its
/// context wait, as in the app. Compacting a context takes `compactionDuration` and leaves a tenth
/// of it; a context at 90% or more is compacted on its own (`compactIfFull(_:)`). A check of a
/// connection takes `checkDuration` and finds a key-based provider without its key.
@MainActor
@Observable
final class MockTeam {

    /// How long a compaction runs.
    var compactionDuration = Duration.milliseconds(1600)

    /// How long a check of a connection runs.
    var checkDuration = Duration.milliseconds(800)

    /// Whether the context ring's popover is open, which the toolbar keeps when it builds its items again.
    var showsContext = false

    /// Whether the token counter's popover is open.
    var showsUsage = false

    /// What the last check of each connection found; absent means not checked yet.
    private(set) var connectionStates: [ModelProvider: ConnectionState] = [
        .codex     : .ready,
        .claudeCode: .ready,
        .anthropic : .credentialMissing,
        .ollama    : .ready,
    ]

    /// The connections being checked now.
    private(set) var checking: Set<ModelProvider> = []

    /// The selections the person changed; the others are the history's.
    private var selections: [MockWorker.ID: ModelSelection] = [:]

    /// The usage records that changed since the mockup opened; the others are the history's.
    private var records: [MockWorker.ID: [WorkerUsage.Record]] = [:]

    private var compacting: Set<MockWorker.ID> = []

    private var browserWindows: Set<MockWorker.ID> = []

    /// Where the histories end, so the times they tell stay put while the mockup runs.
    private let now: Date

    init(now: Date = Date()) {
        self.now = now
    }

    // MARK: Model

    func selection(of worker: MockWorker) -> ModelSelection {
        selections[worker.id] ?? Self.histories[worker.name].map(Self.selection) ?? newWorkerSelection
    }

    func select(
        _ selection: ModelSelection,
        for worker : MockWorker
    ) {
        selections[worker.id] = selection
    }

    /// The provider's models: the fixed list the app falls back to when a listing fails, and two
    /// pulled models for Ollama, which has no fixed list.
    func catalogue(for provider: ModelProvider) -> [ModelInfo] {
        let ids = provider == .ollama ? Self.pulledModels : provider.defaultModels
        return ids.map { id in
            ModelInfo(
                id     : id,
                efforts: ModelSelection.supportedEfforts(
                    provider: provider,
                    model   : id
                )
            )
        }
    }

    /// Moves the worker to `provider`, on the model the app would start it on.
    func changeProvider(
        of worker  : MockWorker,
        to provider: ModelProvider
    ) {
        guard provider != selection(of: worker).provider,
              let model = provider.startingModel(in: catalogue(for: provider))
        else { return }

        selections[worker.id] = ModelSelection(
            provider: provider,
            model   : model.id,
            effort  : model.startingEffort
        )
    }

    // MARK: Turns

    /// Whether the worker is in a turn: busy, or waiting for the person.
    func isAnswering(_ worker: MockWorker) -> Bool {
        worker.status == .busy || worker.status == .waiting
    }

    func isCompacting(_ worker: MockWorker) -> Bool {
        compacting.contains(worker.id)
    }

    /// The worker's current or last turn, with the model it ran with, not the one chosen since.
    func lastTurn(of worker: MockWorker) -> WorkerInspectorView.TurnReading {
        guard let history = Self.histories[worker.name] else { return .nothingYet }

        let state: TurnSummary.State = isAnswering(worker) ? .running : worker.status == .off ? .stopped : .completed
        return .read(TurnSummary(
            startedAt: now.addingTimeInterval(-history.lastTurnAge),
            selection: Self.selection(of: history),
            state    : state
        ))
    }

    // MARK: Usage

    /// The worker's usage on the provider it answers with now.
    func usage(of worker: MockWorker) -> WorkerUsage {
        let provider = selection(of: worker).provider
        return WorkerUsage(
            records   : currentRecords(of: worker),
            provider  : provider,
            rateLimits: rateLimits(of: provider)
        )
    }

    /// Compacts the worker's context, as the context popover asks. Nothing starts while the worker
    /// answers, while it compacts already, or while its context is unknown.
    func compact(
        _ worker: MockWorker,
        trigger : ContextCompaction.Trigger = .manual
    ) {
        let selection = selection(of: worker)
        guard !isAnswering(worker),
              !compacting.contains(worker.id),
              let context = usage(of: worker).context
        else { return }

        compacting.insert(worker.id)
        Task {
            try? await Task.sleep(for: compactionDuration)
            let kept = context.tokens / 10
            records[worker.id] = currentRecords(of: worker) + [
                .turn(TurnUsage(
                    provider     : selection.provider,
                    model        : selection.model,
                    session      : nil,
                    turn         : ProviderUsage.Tokens(
                        input     : context.tokens,
                        cacheReads: context.tokens,
                        output    : kept
                    ),
                    sessionTotal : nil,
                    contextTokens: nil,
                    contextWindow: nil,
                    rateLimits   : [],
                    isCompaction : true
                )),
                .compacted(ContextCompaction(
                    provider     : selection.provider,
                    trigger      : trigger,
                    preTokens    : context.tokens,
                    postTokens   : kept,
                    contextWindow: context.window,
                    summary      : nil
                )),
            ]
            compacting.remove(worker.id)
        }
    }

    /// Compacts the worker's context on its own when it is 90% full or more, as the app does once
    /// a turn leaves it there.
    func compactIfFull(_ worker: MockWorker) {
        guard let fraction = usage(of: worker).context?.fraction,
              UsageWording.contextLevel(fraction) == .full
        else { return }

        compact(
            worker,
            trigger: .automatic
        )
    }

    /// Starts the worker's context over, which leaves its size unknown until its next turn.
    func startFresh(_ worker: MockWorker) {
        guard !isAnswering(worker) else { return }

        records[worker.id] = currentRecords(of: worker) + [.reset]
    }

    // MARK: Connections

    /// How many connections the last checks found ready.
    var readyConnections: Int {
        ModelProvider.allCases.count { connectionStates[$0]?.isReady == true }
    }

    func check(_ provider: ModelProvider) {
        guard !checking.contains(provider) else { return }

        checking.insert(provider)
        Task {
            try? await Task.sleep(for: checkDuration)
            let usesKey = ProviderConnection(provider: provider).authentication == .apiKey
            connectionStates[provider] = usesKey ? .credentialMissing : .ready
            checking.remove(provider)
        }
    }

    // MARK: Web

    func showsBrowserWindow(of worker: MockWorker) -> Bool {
        browserWindows.contains(worker.id)
    }

    func setShowsBrowserWindow(
        _ shows  : Bool,
        of worker: MockWorker
    ) {
        if shows {
            browserWindows.insert(worker.id)
        } else {
            browserWindows.remove(worker.id)
        }
    }

    // MARK: Histories

    /// History is where a sample worker's usage stands when the mockup opens: the model its turns
    /// ran with, how many, what the last one left in the context (nil when a fresh context followed
    /// it) out of the model's window, and how long ago, in seconds, the last one started.
    private typealias History = (
        provider     : ModelProvider,
        model        : String,
        effort       : ReasoningEffort,
        turns        : Int,
        contextTokens: Int?,
        window       : Int,
        lastTurnAge  : TimeInterval
    )

    /// The sample house's workers by name: every level of the ring, one worker past 90% that is
    /// free to compact, one on Codex, one on a model without effort levels, one after a fresh context.
    private static let histories: [String: History] = [
        "Delivery" : (.claudeCode, "claude-opus-5-5",   .high,   18, 68_000,  200_000, 90),
        "Render"   : (.claudeCode, "claude-opus-5-5",   .xhigh,  26, 152_000, 200_000, 240),
        "Mastering": (.claudeCode, "claude-opus-5-5",   .high,   31, 182_000, 200_000, 600),
        "Ingest"   : (.claudeCode, "claude-sonnet-5-5", .medium, 12, 116_000, 200_000, 1_500),
        "Mixing"   : (.claudeCode, "claude-haiku-4-5",  .medium, 9,  44_000,  200_000, 3_600),
        "Design"   : (.claudeCode, "claude-sonnet-5-5", .medium, 6,  24_000,  200_000, 7_200),
        "Export"   : (.claudeCode, "claude-opus-5-5",   .high,   21, 162_000, 200_000, 420),
        "Research" : (.codex,      "gpt-5.6-luna",      .high,   14, 94_000,  272_000, 5_400),
        "PT Agent" : (.claudeCode, "claude-opus-5-5",   .medium, 40, nil,     200_000, 86_400),
    ]

    /// Two models as Ollama's server lists what it has pulled.
    private static let pulledModels = ["qwen3:8b", "gemma3:12b"]

    /// A new worker's selection: the first ready provider, on the model the app starts it on.
    private var newWorkerSelection: ModelSelection {
        let provider = ModelProvider.preselected(in: connectionStates) ?? .claudeCode
        let model    = provider.startingModel(in: catalogue(for: provider))
        return ModelSelection(
            provider: provider,
            model   : model?.id ?? provider.defaultModels.first ?? "",
            effort  : model?.startingEffort ?? .medium
        )
    }

    private static func selection(of history: History) -> ModelSelection {
        ModelSelection(
            provider: history.provider,
            model   : history.model,
            effort  : history.effort
        )
    }

    private func currentRecords(of worker: MockWorker) -> [WorkerUsage.Record] {
        records[worker.id] ?? Self.histories[worker.name].map(Self.records) ?? []
    }

    /// The history's turns, its context growing evenly to where it stands and each turn reading
    /// the context before it from the cache, then a fresh context when it stands nowhere.
    private static func records(of history: History) -> [WorkerUsage.Record] {
        let end   = history.contextTokens ?? history.window / 2
        let start = min(
            12_000,
            end
        )
        var previous = 0
        var turns    = [WorkerUsage.Record]()
        for index in 1...history.turns {
            let context = start + (end - start) * index / history.turns
            let output  = max(
                600,
                (context - previous) / 4
            )
            turns.append(.turn(TurnUsage(
                provider     : history.provider,
                model        : history.model,
                session      : nil,
                turn         : ProviderUsage.Tokens(
                    input      : context,
                    cacheReads : previous,
                    cacheWrites: context - previous,
                    output     : output,
                    reasoning  : history.provider == .codex ? output / 3 : 0
                ),
                sessionTotal : nil,
                contextTokens: context,
                contextWindow: history.window,
                rateLimits   : []
            )))
            previous = context
        }
        return history.contextTokens == nil ? turns + [.reset] : turns
    }

    /// The account's limits on `provider`: Claude's five hours and week, Codex's two windows, the
    /// second past 75%, and none for the others.
    private func rateLimits(of provider: ModelProvider) -> [ProviderUsage.RateLimit] {
        switch provider {
        case .claudeCode:
            [
                ProviderUsage.RateLimit(
                    window      : "five_hour",
                    usedFraction: 0.42,
                    resetsAt    : now.addingTimeInterval(7_800)
                ),
                ProviderUsage.RateLimit(
                    window      : "seven_day",
                    usedFraction: 0.18,
                    resetsAt    : now.addingTimeInterval(259_200)
                ),
            ]
        case .codex:
            [
                ProviderUsage.RateLimit(
                    window       : "primary",
                    usedFraction : 0.27,
                    resetsAt     : now.addingTimeInterval(9_000),
                    windowMinutes: 300
                ),
                ProviderUsage.RateLimit(
                    window       : "secondary",
                    usedFraction : 0.81,
                    resetsAt     : now.addingTimeInterval(345_600),
                    windowMinutes: 10_080
                ),
            ]
        case .anthropic, .gemini, .ollama:
            []
        }
    }
}

private extension TurnSummary {

    /// A turn as the mock's history tells it, with no execution behind it.
    init(
        startedAt: Date,
        selection: ModelSelection,
        state    : State
    ) {
        self.executionID = UUID()
        self.startedAt   = startedAt
        self.selection   = selection
        self.state       = state
    }
}
