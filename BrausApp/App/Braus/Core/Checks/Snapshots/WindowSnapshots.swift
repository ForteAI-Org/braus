//
//  WindowSnapshots.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Memory
import ModelTransports
import SeatBroker
import SwiftUI

/// WindowSnapshots draws the team window's content offscreen into PNGs for a
/// person to look at, when the app is launched with BRAUS_SNAPSHOTS=1, then
/// quits. The files go to BRAUS_SNAPSHOT_DIR, or under the temporary directory.
///
/// The real `HouseShellView` is hosted in a window that is never ordered on
/// screen (`writeHouseWindow`), and the sheets, popovers and Settings pages are
/// drawn alone with `cacheDisplay`, so nothing needs a Screen Recording grant
/// and Stage Manager has nothing to hide. Braus is dark only, so is every
/// picture. The team is synthetic, in a store of its own under the temporary
/// directory; the person's workspace is not opened.
@MainActor
enum WindowSnapshots {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["BRAUS_SNAPSHOTS"] == "1" }

    /// True while a snapshot draws the composer with its model popup open.
    static var opensModelPopup = false

    /// True while a snapshot draws the conversation as the person uses the worker's application.
    static var showsHumanControl = false

    /// The defaults the drawn views read, a suite of their own apart from the person's.
    static let appStorage = UserDefaults(suiteName: "dev.forte.Braus.snapshots")

    /// A turn that read a page and searched the web, as `WebToolRecords` writes it.
    private static let webTools = [
        "» I’ll check the release notes first.",
        "→ web_fetch {\"url\":\"https://www.swift.org/blog/\"}",
        "→ web_search {\"query\":\"capture suite timeout on a virtual display\"}",
        "← web_fetch done",
        "← web_search done",
    ]

    /// Writes every snapshot, prints each path, and ends the process: 0 when
    /// all were written, 1 with the reason on standard error otherwise.
    static func writeAndQuit() async {
        let store = URL.temporaryDirectory.appending(
            path         : "BrausWindowSnapshots-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        var status: Int32 = 0

        do {
            let team   = try await syntheticTeam(
                in           : store,
                contextTokens: 142_318
            )
            let output = try directory()

            // Codex's catalogue as the composer's popup lists it, without running the command line.
            team.connections.recordCatalogue(
                [
                    ModelInfo(
                        id     : "gpt-5.4-mini",
                        title  : "GPT-5.4-Mini",
                        efforts: [.low, .medium, .high, .xhigh]
                    ),
                    ModelInfo(
                        id     : "gpt-5.6-luna",
                        title  : "GPT-5.6-Luna",
                        efforts: [.low, .medium, .high, .xhigh, .max]
                    ),
                ],
                for: .codex
            )

            try await writeHouse(from: team, in: store, to: output)

            // The model popup open above the composer, in the narrowest window, where it has least room.
            opensModelPopup = true
            try await writeHouseWindow(
                team,
                width    : HouseWindowLayout.minimumWidth,
                inspector: true,
                to       : output.appending(path: "house-model-popup.png")
            )
            opensModelPopup = false

            // The context ring green, orange and red, its button drawn alone in a capsule like the toolbar's,
            // since offscreen the toolbar draws the window's glass blank.
            for (level, tokens) in [("roomy", 142_318), ("filling", 219_640), ("full", 240_000)] {
                guard let ring = WorkerUsage(
                    turns     : [atlasUsage(contextTokens: tokens)],
                    provider  : .codex,
                    rateLimits: []
                ).context else { throw SnapshotFailure("no context at \(tokens) tokens") }

                try await write(
                    ringButton(ConversationContextButton(
                        context     : ring,
                        worker      : "Atlas",
                        isCompacting: false,
                        waitReason  : nil,
                        compact     : {},
                        startFresh  : {}
                    )),
                    width : 96,
                    height: 96,
                    to    : output.appending(path: "context-ring-\(level).png")
                )
            }

            // The composer with a pill grown to several lines.
            let grown = try await syntheticTeam(in: store.appending(
                path         : "Grown",
                directoryHint: .isDirectory
            ))
            grown.draft = "Rerun the capture suite first.\nThen the layout suite.\nThen send me both logs."
            try await writeHouseWindow(
                grown,
                width    : 1200,
                inspector: false,
                to       : output.appending(path: "house-composer-grown.png")
            )

            // The two usage popovers drawn alone, as a popover is a window of its own.
            let atlas = WorkerUsage(
                turns     : [atlasUsage(contextTokens: 142_318)],
                provider  : .codex,
                rateLimits: []
            )
            guard let context = atlas.context else { throw SnapshotFailure("no context in Atlas's usage") }

            let popovers: [(name: String, popover: AnyView, height: Double)] = [
                ("context-popover", AnyView(ConversationContextPopover(
                    context   : context,
                    waitReason: nil,
                    compact   : {},
                    startFresh: {}
                )), 230),
                ("token-counter-popover", AnyView(TokenCounterPopover(
                    workerName: "Iris",
                    provider  : .claudeCode,
                    usage     : planUsage()
                )), 420),
            ]
            for popover in popovers {
                try await write(
                    popover.popover.background(Color(nsColor: .windowBackgroundColor)),
                    width : 280,
                    height: popover.height,
                    to    : output.appending(path: "\(popover.name).png")
                )
            }

            // The ring while the context is compacted, its button drawn alone in the same capsule.
            try await write(
                ringButton(ConversationContextButton(
                    context     : context,
                    worker      : "Atlas",
                    isCompacting: true,
                    waitReason  : nil,
                    compact     : {},
                    startFresh  : {}
                )),
                width : 96,
                height: 96,
                to    : output.appending(path: "context-ring-compacting.png")
            )

            // Atlas's conversation after Braus compacted its context on its own.
            let compacted = try await syntheticTeam(
                in           : store.appending(
                    path         : "Compacted",
                    directoryHint: .isDirectory
                ),
                contextTokens: 236_900,
                compaction   : .automatic
            )
            try await writeHouseWindow(
                compacted,
                width    : 1200,
                inspector: false,
                to       : output.appending(path: "house-compacted.png")
            )

            // Atlas's conversation after the person handed an application back: one row, then its answer.
            let handedBack = try await syntheticTeam(
                in      : store.appending(
                    path         : "HandBack",
                    directoryHint: .isDirectory
                ),
                handBack: true
            )
            try await writeHouseWindow(
                handedBack,
                width    : 1200,
                inspector: false,
                to       : output.appending(path: "house-handback.png")
            )

            // Atlas's conversation while the person uses Pro Tools in its place.
            let takenOver = try await syntheticTeam(
                in       : store.appending(
                    path         : "TakenOver",
                    directoryHint: .isDirectory
                ),
                takenOver: true
            )
            showsHumanControl = true
            try await writeHouseWindow(
                takenOver,
                width    : 1200,
                inspector: false,
                to       : output.appending(path: "house-human-control.png")
            )
            showsHumanControl = false

            // Atlas's conversation after the person ended control without handing Pro Tools back.
            let stopped = try await syntheticTeam(
                in       : store.appending(
                    path         : "Stopped",
                    directoryHint: .isDirectory
                ),
                takenOver: true,
                stopped  : true
            )
            try await writeHouseWindow(
                stopped,
                width    : 1200,
                inspector: false,
                to       : output.appending(path: "house-stopped.png")
            )

            // Atlas's turn read a page and searched the web: its tool line closed, then open.
            let searched = try await syntheticTeam(
                in   : store.appending(
                    path         : "Web",
                    directoryHint: .isDirectory
                ),
                tools: webTools
            )
            guard let appStorage else { throw SnapshotFailure("no defaults of the snapshots' own") }
            do {
                defer { appStorage.removeObject(forKey: AppPreferences.chatOpensToolSteps) }
                for opens in [false, true] {
                    appStorage.set(
                        opens,
                        forKey: AppPreferences.chatOpensToolSteps
                    )
                    try await writeHouseWindow(
                        searched,
                        width    : 1200,
                        inspector: false,
                        to       : output.appending(path: "house-web\(opens ? "-open" : "").png")
                    )
                }
            }

            // The inspector drawn alone, as the split draws it blank offscreen, with the selected
            // worker's list of providers open.
            if let worker = team.selectedWorker {
                team.choosingProviderFor = worker.id
                team.connections.recordCheck(
                    .credentialMissing,
                    for: .anthropic,
                    at : Self.checkedAt
                )
                try await write(
                    HouseLiveInspector.Content(
                        team  : team,
                        worker: worker
                    )
                    .background(Color("HouseInspector")),
                    width : HouseWindowLayout.inspectorWidth.ideal,
                    height: 900,
                    to    : output.appending(path: "inspector-providers.png")
                )
                team.choosingProviderFor = nil
            }

            // Settings, the window and each page alone, as the split may draw its sidebar blank offscreen.
            let broker = SeatBroker(configuration: .init(allowUnvalidatedBuild: true))
            try await write(
                SettingsView(
                    store : team.connections,
                    broker: broker,
                    pane  : .provider(.claudeCode)
                ),
                width : 720,
                height: 540,
                to    : output.appending(path: "settings-window.png")
            )
            let pages: [(name: String, page: AnyView)] = [
                ("general", AnyView(GeneralSettings())),
                ("computer", AnyView(ComputerSettings(broker: broker))),
                ("virtual-display", AnyView(VirtualDisplaySettings(broker: broker))),
                ("sidebar", AnyView(SidebarSettings())),
                ("chat", AnyView(ChatSettings())),
                ("claude", AnyView(ProviderSettingsPage(store: team.connections, provider: .claudeCode))),
                ("codex", AnyView(ProviderSettingsPage(store: team.connections, provider: .codex))),
                ("anthropic", AnyView(ProviderSettingsPage(store: team.connections, provider: .anthropic))),
                ("gemini", AnyView(ProviderSettingsPage(store: team.connections, provider: .gemini))),
                ("ollama", AnyView(ProviderSettingsPage(store: team.connections, provider: .ollama))),
            ]
            for page in pages {
                try await write(
                    page.page,
                    width : 530,
                    height: 700,
                    to    : output.appending(path: "settings-\(page.name).png")
                )
            }

            // The Brain, from a knowledge directory the run names, since the snapshot store learns nothing.
            if let knowledge = ProcessInfo.processInfo.environment["BRAUS_SNAPSHOT_KNOWLEDGE_DIR"],
               case .loaded(let known) = await BrainLibrary.apps(in: URL(filePath: knowledge, directoryHint: .isDirectory)),
               let app = known.first {
                let brains: [(name: String, page: AnyView)] = [
                    ("brain-apps", AnyView(BrainSettings(directory: URL(filePath: knowledge, directoryHint: .isDirectory)))),
                    ("brain-graph", AnyView(BrainGraphView(simulation: BrainSimulation(graph: BrainGraph(brain: app.brain))))),
                    ("brain-list", AnyView(BrainListView(
                        brain: app.brain,
                        opens: Set(app.brain.groups.prefix(2).map(\.id))
                    ))),
                ]
                for brain in brains {
                    try await write(
                        brain.page,
                        width : 640,
                        height: 560,
                        to    : output.appending(path: "settings-\(brain.name).png")
                    )
                }
            }

            try await write(
                ConnectionsSheet(
                    connections   : syntheticConnections(),
                    checksOnAppear: false,
                    opens         : [.claudeCode]
                ),
                width : 520,
                height: 600,
                to    : output.appending(path: "connections.png")
            )

            try await write(
                PermissionsSheet(broker: SeatBroker(configuration: .init(allowUnvalidatedBuild: true))),
                width : 520,
                height: 420,
                to    : output.appending(path: "mac-access.png")
            )

            // The sheet with Codex ready and its recorded catalogue, then with nothing connected.
            let ready: [ModelProvider: ConnectionState] = [.codex: .ready]
            for (state, connections) in [("", ready), ("-unconnected", [:])] {
                try await write(
                    HouseNewWorkerSheet(
                        shapes     : HouseRoster.workers(of: team).map(\.shape),
                        connections: { connections },
                        catalogue  : { provider in team.connections.catalogues[provider] ?? [] }
                    ) { _ in },
                    width : 460,
                    height: 570,
                    to    : output.appending(path: "new-worker\(state).png")
                )
            }

            // The composer's model popup, at the bottom, the middle and the top of a Codex model's rail.
            let codex = ModelInfo(
                id           : "gpt-6-sol",
                title        : "GPT-6-Sol",
                efforts      : [.low, .medium, .high, .xhigh, .max, .ultra],
                defaultEffort: .medium
            )
            for effort in [ReasoningEffort.low, .high, .ultra] {
                try await write(
                    ConversationModelPopup(
                        selection: .constant(ModelSelection(
                            provider: .codex,
                            model   : codex.id,
                            effort  : effort
                        )),
                        catalogue: [codex]
                    )
                    .padding(24)
                    .background(Color(nsColor: .windowBackgroundColor)),
                    width : 368,
                    height: 180,
                    to    : output.appending(path: "model-popup-\(effort.rawValue).png")
                )
            }

            let models = [codex] + ["GPT-6-Astra", "GPT-6-Luna", "GPT-5.6-Sol", "GPT-5.5"].map { title in
                ModelInfo(
                    id     : title.lowercased(),
                    title  : title,
                    efforts: [.low, .medium, .high]
                )
            }
            try await write(
                ConversationModelPopup(
                    selection  : .constant(ModelSelection(
                        provider: .codex,
                        model   : codex.id,
                        effort  : .high
                    )),
                    catalogue  : models,
                    showsModels: true
                )
                .padding(24)
                .background(Color(nsColor: .windowBackgroundColor)),
                width : 368,
                height: 300,
                to    : output.appending(path: "model-popup-list.png")
            )

            try await writeReply(to: output)
            try await writeSlashCommands(to: output)
        } catch {
            FileHandle.standardError.write(Data("snapshots failed: \(error)\n".utf8))
            status = 1
        }

        // A leftover temporary store is reclaimed by the system; it must not change the exit status.
        do { try FileManager.default.removeItem(at: store) } catch {}
        exit(status)
    }

    /// `button`, the context ring, alone in a capsule like the toolbar's.
    private static func ringButton(_ button: ConversationContextButton) -> some View {
        button
            .buttonStyle(.plain)
            .frame(height: 36)
            .padding(
                .horizontal,
                8
            )
            .background(
                .quinary,
                in: Capsule()
            )
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func directory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let directory   = environment["BRAUS_SNAPSHOT_DIR"].map {
            URL(
                filePath     : $0,
                directoryHint: .isDirectory
            )
        } ?? URL.temporaryDirectory.appending(
            path         : "BrausWindowSnapshots",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at                         : directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    // MARK: The team

    /// Three workers and Atlas's conversation: an earlier exchange, then one
    /// finished turn whose profile was changed afterwards, so the inspector has
    /// to show the turn's model and not the profile's. With `contextTokens` the
    /// turn records its usage too (`atlasUsage`), so the toolbar's context ring and the
    /// token counter are drawn. With `compaction` the context is compacted
    /// after the turn, to 38,200 tokens. `tools` are the turn's tool records.
    /// With `handBack` the person then hands an application back, and Atlas answers the summary.
    /// With `takenOver` the last message's turn ends with the person taking its application over,
    /// and with `stopped` too the person then ends control without handing it back.
    static func syntheticTeam(
        in directory : URL,
        contextTokens: Int?                       = nil,
        compaction   : ContextCompaction.Trigger? = nil,
        handBack     : Bool                       = false,
        takenOver    : Bool                       = false,
        stopped      : Bool                       = false,
        tools        : [String]                   = [
            "→ read_log {\"job\":\"nightly\"}",
            "← read_log 2 bundles failed",
        ]
    ) async throws -> TeamModel {
        let store = try WorkspaceStore.opening(in: directory)
        let iris  = try await store.createWorker(
            name      : "Iris",
            role      : "Research lead",
            appearance: WorkerAppearance(
                seed   : 11,
                palette: "dusk"
            )
        )
        let atlas = try await store.createWorker(
            name      : "Atlas",
            role      : "Release engineer",
            appearance: WorkerAppearance(
                seed   : 7,
                palette: "tide"
            )
        )
        try await store.createWorker(
            name      : "Nova",
            role      : "Editor",
            appearance: WorkerAppearance(
                seed   : 23,
                palette: "ember"
            )
        )
        try await store.configure(
            worker   : iris.id,
            selection: ModelSelection(
                provider: .claudeCode,
                model   : "claude-opus-5",
                effort  : .high
            )
        )
        try await store.configure(
            worker   : atlas.id,
            selection: ModelSelection(
                provider: .codex,
                model   : "gpt-5.6-luna",
                effort  : .high
            )
        )

        let conversation = try await store.createConversation(
            kind        : .direct,
            participants: [atlas.id]
        )
        let origin = Date(timeIntervalSinceReferenceDate: 780_000_000)

        // An earlier exchange long enough that, opened at its end, older messages pass under the header.
        for index in 0..<8 {
            let asked = origin.addingTimeInterval(Double(index - 8) * 300)
            try await store.appendMessage(
                to      : conversation.id,
                text    : "Is step \(index + 1) of the release done?",
                at      : asked,
                delivery: .completed
            )
            try await store.appendMessage(
                to      : conversation.id,
                author  : atlas.id,
                text    : "Step \(index + 1) is done. The notes are in the release folder, "
                    + "and nothing is blocking the next one.",
                at      : asked.addingTimeInterval(30),
                delivery: .completed
            )
        }

        let ask = try await store.appendMessage(
            to      : conversation.id,
            text    : "Can you check this morning's build and tell me what failed?",
            at      : origin,
            delivery: .completed
        )
        let turn = try await store.startExecution(
            worker      : atlas.id,
            conversation: conversation.id,
            at          : origin.addingTimeInterval(1)
        )
        let workspaceID = UUID()

        func record(
            _ type    : EventType,
            at seconds: Double,
            text      : String? = nil
        ) async throws {
            try await store.append(NewEvent(
                workspaceID   : workspaceID,
                subjectID     : turn.id,
                conversationID: conversation.id,
                workerID      : atlas.id,
                timestamp     : origin.addingTimeInterval(seconds),
                type          : type,
                payload       : text.map { Data($0.utf8) },
                correlationID : ask.id
            ))
        }

        try await record(
            .executionStarted,
            at: 1
        )
        for (index, line) in tools.enumerated() {
            try await record(
                .toolActivity,
                at  : 2 + Double(index),
                text: line
            )
        }
        if let contextTokens {
            let usage = try atlasUsage(contextTokens: contextTokens).encoded()
            try await record(
                .turnUsage,
                at  : 20,
                text: String(
                    decoding: usage,
                    as      : UTF8.self
                )
            )
        }
        try await store.appendMessage(
            to      : conversation.id,
            author  : atlas.id,
            text    : """
                The build finished at 07:42. Two bundles failed: the capture suite timed out once on \
                the virtual display, and the layout suite failed on a width assertion. The capture \
                timeout looks flaky; the width assertion is real and reproduces locally.
                """,
            at      : origin.addingTimeInterval(20),
            delivery: .completed
        )
        try await record(
            .executionCompleted,
            at: 21
        )
        if let compaction {
            let compacted = ContextCompaction(
                provider     : .codex,
                trigger      : compaction,
                preTokens    : contextTokens,
                postTokens   : 38_200,
                contextWindow: 258_400,
                summary      : nil
            )
            try await store.append(NewEvent(
                workspaceID   : workspaceID,
                subjectID     : conversation.id,
                conversationID: conversation.id,
                workerID      : atlas.id,
                timestamp     : origin.addingTimeInterval(40),
                type          : .contextCompacted,
                payloadVersion: ContextCompaction.payloadVersion,
                payload       : try compacted.encoded()
            ))
        }
        if handBack {
            try await store.appendMessage(
                to              : conversation.id,
                text            : "Human control ended.\nclicked Run in Xcode\nFinal state: capture suite running",
                at              : origin.addingTimeInterval(50),
                delivery        : .completed,
                endsHumanControl: true
            )
            try await store.appendMessage(
                to      : conversation.id,
                author  : atlas.id,
                text    : "You started the capture suite again in Xcode. I’ll watch it and tell you how it ends.",
                at      : origin.addingTimeInterval(60),
                delivery: .completed
            )
        }
        if takenOver {
            let ask = try await store.appendMessage(
                to      : conversation.id,
                text    : "Open Pro Tools and add a stereo track.",
                at      : origin.addingTimeInterval(70),
                delivery: .completed
            )
            let turn = try await store.startExecution(
                worker      : atlas.id,
                conversation: conversation.id,
                at          : origin.addingTimeInterval(71)
            )
            for (second, type, text) in [
                (71.0, EventType.executionStarted, nil),
                (72, .toolActivity, "→ open_session {\"app\":\"Pro Tools\"}"),
                (73, .toolActivity, "← open_session {\"session\":\"s\"}"),
                (74, .executionHandedToPerson, nil),
            ] as [(Double, EventType, String?)] {
                try await store.append(NewEvent(
                    workspaceID   : workspaceID,
                    subjectID     : turn.id,
                    conversationID: conversation.id,
                    workerID      : atlas.id,
                    timestamp     : origin.addingTimeInterval(second),
                    type          : type,
                    payload       : text.map { Data($0.utf8) },
                    correlationID : ask.id
                ))
            }
            if stopped {
                try await store.append(NewEvent(
                    workspaceID   : workspaceID,
                    subjectID     : conversation.id,
                    conversationID: conversation.id,
                    workerID      : atlas.id,
                    timestamp     : origin.addingTimeInterval(80),
                    type          : .humanControlStopped
                ))
            }
        } else {
            try await store.appendMessage(
                to      : conversation.id,
                text    : "Rerun the capture suite first.",
                at      : origin.addingTimeInterval(90),
                delivery: .savedLocally
            )
        }
        try await store.configure(
            worker   : atlas.id,
            selection: ModelSelection(
                provider: .codex,
                model   : "gpt-5.4-mini",
                effort  : .low
            )
        )

        let team = TeamModel(
            store      : store,
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await team.load()
        team.selection = atlas.id
        await team.openSelectedConversation()
        return team
    }

    /// When the synthetic checks finished, fixed so the images do not change with the clock.
    private static let checkedAt = Date(timeIntervalSinceReferenceDate: 780_000_000)

    /// One connection in each kind of state the sheet draws, recorded rather
    /// than checked. Whether a key is held still comes from the keychain,
    /// which decides only which key actions show; no key is ever drawn.
    private static func syntheticConnections() -> ModelSettingsStore {
        let connections = ModelSettingsStore()
        connections.recordCheck(
            .ready,
            for: .codex,
            at : checkedAt
        )
        connections.recordCheck(
            .ready,
            for: .claudeCode,
            at : checkedAt.addingTimeInterval(-60)
        )
        connections.recordCheck(
            .credentialMissing,
            for: .anthropic,
            at : checkedAt
        )
        connections.recordCheck(
            .credentialRejected(detail: "API key not valid. Please pass a valid API key."),
            for: .gemini,
            at : checkedAt
        )
        connections.recordCheck(
            .unreachable(
                destination: connections.ollamaHost,
                detail     : "Could not connect to the server."
            ),
            for: .ollama,
            at : checkedAt
        )
        return connections
    }

    // MARK: Drawing

    /// Hosts `content` at `width` by `height`, lets its tasks and the transcript
    /// settle, then draws the window's frame view, which holds the toolbar too.
    static func write(
        _ content: some View,
        width    : Double,
        height   : Double = 720,
        to file  : URL
    ) async throws {
        // Offscreen, SwiftUI resolves its colours in the app's appearance rather than the window's.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: content
            .defaultAppStorage(appStorage ?? .standard))
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(
            contentRect: NSRect(
                x     : 0,
                y     : 0,
                width : width,
                height: height
            ),
            styleMask  : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.appearance           = NSAppearance(named: .darkAqua)
        window.contentView          = hosting
        window.setContentSize(NSSize(
            width : width,
            height: height
        ))

        // SwiftUI lays out over several passes and the transcript loads off the main actor.
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }

        let frame = window.contentView?.superview ?? hosting
        frame.layoutSubtreeIfNeeded()
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            throw SnapshotFailure("no bitmap for \(file.lastPathComponent)")
        }

        frame.cacheDisplay(
            in: frame.bounds,
            to: bitmap
        )
        guard let png = bitmap.representation(
            using     : .png,
            properties: [:]
        ) else {
            throw SnapshotFailure("no PNG for \(file.lastPathComponent)")
        }

        try png.write(to: file)
        window.close()
        print("snapshot: \(file.path)")
    }

    private struct SnapshotFailure: Error, CustomStringConvertible {

        let description: String

        init(_ description: String) { self.description = description }
    }
}
