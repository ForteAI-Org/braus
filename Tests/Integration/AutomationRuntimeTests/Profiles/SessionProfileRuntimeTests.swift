@testable import AutomationMCP
@testable import AutomationRuntime
import Capabilities
import Foundation
import EngineCore
import PerceptionCore
import LocalMCP
import Memory
import Switches
import SQLiteMemory
import Testing

@MainActor
@Suite("SessionProfile runtime", .serialized)
struct SessionProfileRuntimeTests {
    typealias P = ProcedureLearningTests

    @Test(arguments: SessionProfile.Memory.allCases)
    func learningIsBlockedAtEveryPoint(_ mode: SessionProfile.Memory) async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        let tools = AutomationTools(session: session, profile: SessionProfile.cli.replacing(memory: mode))
        tools.producer = CallProducer(source: .cli, streamID: "juniper")
        let begun = try await P.task(tools, #"{"operation":"begin","goal":"Rotate and mark the image"}"#)
        #expect(begun["status"].string == "begun")
        _ = try await P.call(tools, "open_session", #"{"app":"com.apple.Preview"}"#)
        let id = try #require(session.id?.uuidString)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Markup"}"#)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        #expect(ended["status"].string == "ended")
        await tools.afterTurn()
        if mode.learns { _ = await tools.interpretLeftCandidate() }
        #expect(await memory.flush(within: .seconds(10)))
        for table in ["memory_events", "memory_agent_actions", "memory_event_observations", "memory_task_events"] {
            #expect(try RecallProductPathTests.count(table, session) > 0, "Facts must remain in \(table)")
        }
        for table in ["brain_applications", "brain_anchors"] {
            #expect(try RecallProductPathTests.count(table, session) == 0, "The historical projection stays frozen")
        }
        let scenes = try RecallProductPathTests.count("brain_scenes", session)
        #expect(mode.learns ? scenes > 0 : scenes == 0)

        #expect(mode.learns || tools.pendingCandidate == nil)
        for table in ["memory_procedure_candidates", "memory_procedure_interpretations", "memory_procedure_versions"] {
            let count = try RecallProductPathTests.count(table, session)
            #expect(mode.learns ? count > 0 : count == 0, "Procedure writes in \(table): \(count)")
        }
        await RecallLifecycleTests.close(session)
    }

    @Test func listIsFixedForTheSession() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": "v2", "task_cycle": "v2"])) {
            let session = P.photoSession(try W.directory())
            let tools = AutomationTools(session: session, channels: [.web], profile: .app)
            let initial = tools.toolDefinitions
            tools.adapters = nil
            tools.router = nil
            #expect(tools.toolDefinitions == initial)
            #expect(tools.toolDefinitions == tools.dispatcher.toolDefinitions)
            #expect(tools.instructions == AutomationTools.instructions(for: [.web]))
            await tools.afterTurn()
            #expect(tools.toolDefinitions == initial)
            #expect(tools.toolDefinitions == tools.dispatcher.toolDefinitions)
            await RecallLifecycleTests.close(session)
        }
    }

    @Test func statusNamesTheProfileAndNoCredential() async throws {
        let session = P.photoSession(try W.directory())
        var options = SessionProfile.cli.options
        options.providerCredential = .namedVariable("JUNIPER_TOKEN")
        let tools = AutomationTools(session: session, profile: SessionProfile.cli.replacing(options: options))
        let status = try await P.task(tools, #"{"operation":"status"}"#)
        #expect(status["profile"]["readsMemory"].bool == true)
        let encoded = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(!encoded.contains("JUNIPER_TOKEN"))
        await RecallLifecycleTests.close(session)
    }

    @Test func switchesFromTheProfileReachTheSwitchReader() async throws {
        let session = P.photoSession(try W.directory())
        var options = SessionProfile.cli.options
        options.switches = ["brain_enrichment": "off"]
        let tools = AutomationTools(session: session, profile: SessionProfile.cli.replacing(options: options))
        let status = try await P.task(tools, #"{"operation":"status"}"#)
        #expect(status["switches"]["brain_enrichment"].string == "off")
        await RecallLifecycleTests.close(session)
    }
}

extension SessionProfileRuntimeTests {
    @Test func readAndLearnShareAnIndexWithoutChangingEachOther() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await RecallLifecycleTests.learnPhoto(session)
        let service = RecallService.shared(for: MemoryService.shared(for: session.directory))
        let request = try RecallRequest(taskID: "juniper", attemptID: "first", revision: 1,
                                        reason: .initial, remainingWork: "Rotate and export the image")
        let read = SessionProfile.cli.replacing(memory: .read).memoryAccess
        let learn = SessionProfile.cli.replacing(memory: .learn).memoryAccess
        for _ in 0..<2 {
            let skipped = try await service.prepare(request, access: learn)
            let searched = try await service.prepare(request, access: read)
            #expect(!skipped.readsMemory && skipped.considered == 0 && skipped.reason == .profileDoesNotReadMemory)
            #expect(searched.readsMemory && searched.considered > 0)
            #expect(await service.index(searched.status, searchStatus: searched.searchStatus, generation: nil,
                                  readsMemory: searched.readsMemory).status != "off")
        }
        async let skipped = service.prepare(request, access: learn)
        async let searched = service.prepare(request, access: read)
        let (left, right) = try await (skipped, searched)
        #expect(!left.readsMemory && left.considered == 0)
        #expect(right.readsMemory && right.considered > 0)
        await RecallLifecycleTests.close(session)
    }

    @Test func guidesComeFromTheProfile() async throws {
        let session = P.photoSession(try W.directory())
        let url = session.directory.appendingPathComponent("Juniper.md")
        try Data("""
        ---
        {"app":"com.example.Juniper","appVersions":null,"locale":"en","revision":1,"name":"Juniper","description":"Drawing"}
        ---
        A canvas holds the drawing.
        The sidebar holds layers.
        ## Export
        Save the image.
        """.utf8).write(to: url)
        var options = SessionProfile.cli.options
        options.guides = [url]
        let tools = AutomationTools(session: session, profile: SessionProfile.cli.replacing(options: options))
        let initial = tools.toolDefinitions
        try await tools.prepareGuides()
        #expect(tools.guidesEnabled)
        #expect(tools.toolDefinitions == initial)
        try await tools.prepareGuides()
        #expect(tools.toolDefinitions == initial)
        let guide = tools.guides?.head(for: OpenedApp(bundleID: "com.example.Juniper", version: nil, locale: "en-US"))
        #expect(guide?.text == "A canvas holds the drawing.\nThe sidebar holds layers.")
        options.switches = ["guide_delivery": "requested"]
        let requested = AutomationTools(session: session, profile: SessionProfile.cli.replacing(options: options),
            resolveGuideApp: { OpenedApp(bundleID: $0, version: nil, locale: "en-US") })
        let fixed = requested.toolDefinitions
        try await requested.prepareGuides()
        #expect(requested.guidesEnabled)
        #expect(requested.toolDefinitions == fixed)
        let answer = try await requested.call("read_guide", .object(["app": .string("com.example.Juniper")]))
        #expect(answer["isError"].bool != true)
        #expect(answer["content"].array?.first?["text"].string?.contains("A canvas holds the drawing.") == true)
        let unchanged = AutomationTools(session: session, profile: .cli)
        try await unchanged.prepareGuides()
        #expect(unchanged.guides == nil)
        await RecallLifecycleTests.close(session)
    }

    @Test func stdioServerTakesProfileAndInstructions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Tools/Driver/CUAComparison/Server/main.swift"), encoding: .utf8)
        #expect(source.contains("CommandLine.arguments[2] == \"--client\""))
        #expect(source.contains("profile: client ? .mcpClient("))
        #expect(source.contains("mcpInstructions(client ? .full : .firstLine)"))
        #expect(source.contains("tools: tools.toolDefinitions"))
    }
}

extension SessionProfileRuntimeTests {
    @Test func scenesStillEnrichedWhenNotLearning() async throws {
        let memory = try W.service()
        let window = W.window([W.format, W.save])
        _ = await W.recorder(memory).observe(window)
        #expect(await memory.flush(within: .seconds(10)))
        let brain = W.brain(memory)
        let expected = await brain.enrich(window.scene, window: window)
        let recorder = CallRecorder(memory: memory, brain: brain,
            context: ActionContext(source: .cli, streamID: "juniper"),
            access: SessionProfile.cli.replacing(memory: .read).memoryAccess)
        let shown = await recorder.observe(window)
        #expect(shown == expected)
        #expect(await memory.flush(within: .seconds(10)))
        #expect(try await memory.perform { try await $0.applications.application(.observe(
            CaptureSampleKey(eventID: recorder.eventID, phase: .current))) } == nil)
        await memory.close()
    }
}

extension SessionProfileRuntimeTests {
    @Test func observationAllowsExplicitOpeningAndRefusesGestures() async throws {
        let session = P.photoSession(try W.directory())
        let profile = SessionProfile(attendance: .none, level: .observe, memory: .read,
                                     catalogue: .open, takeover: false, options: .init(), name: "Juniper")
        let tools = AutomationTools(session: session, profile: profile)
        _ = try await P.call(tools, "open_session", #"{"app":"com.apple.Preview"}"#)
        let id = try #require(session.id?.uuidString)
        await #expect(throws: (any Error).self) {
            try await P.call(tools, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        }
        await RecallLifecycleTests.close(session)
    }
}

extension SessionProfileRuntimeTests {
    @Test func listChangesOnlyWithAttendanceAndLevel() async throws {
        let session = P.photoSession(try W.directory())
        for base in [SessionProfile.app, .cli, .mcpClient(name: "Juniper", attendance: .client)] {
            let initial = AutomationTools(session: session, profile: base).toolDefinitions
            for memory in SessionProfile.Memory.allCases {
                var options = base.options
                options.harnessWebSearch.toggle()
                options.guides = [session.directory.appendingPathComponent("Juniper.md")]
                options.switches = ["brain_enrichment": "off"]
                let changed = SessionProfile(attendance: base.attendance, level: base.level, memory: memory,
                    archive: session.directory, catalogue: .open, takeover: !base.takeover,
                    mandate: session.directory.appendingPathComponent("task.txt"), options: options, name: "Juniper")
                #expect(AutomationTools(session: session, profile: changed).toolDefinitions == initial)
            }
        }
        await RecallLifecycleTests.close(session)
    }
}


extension SessionProfileRuntimeTests {
    @Test func profileBuildsTheDispatcherToolList() async throws {
        let session = P.photoSession(try W.directory())
        for base in [SessionProfile.app, .cli, .mcpClient(name: "Juniper", attendance: .client)] {
            let tools = AutomationTools(session: session, profile: base)
            #expect(tools.toolList.attendance == base.attendance)
            #expect(tools.toolList.level == base.level)
        }
        await RecallLifecycleTests.close(session)
    }
}


extension SessionProfileRuntimeTests {
    @Test func defaultProfilePreservesExistingToolDefinitions() async throws {
        let session = P.photoSession(try W.directory())
        let baseline = AutomationTools(session: session)
        let explicit = AutomationTools(session: session, profile: .app)
        #expect(baseline.toolDefinitions == explicit.toolDefinitions)
        #expect(baseline.instructions == explicit.instructions)
        await RecallLifecycleTests.close(session)
    }
}

extension SessionProfileRuntimeTests {
    @Test func rawMemoryReadReasonNeverReachesTheModel() async throws {
        let session = P.photoSession(try W.directory())
        let tools = AutomationTools(session: session, profile: SessionProfile.cli.replacing(memory: .off))
        _ = try await P.task(tools, #"{"operation":"begin","goal":"Export"}"#)
        let result = try await P.task(tools, #"{"operation":"recall","reason":"new_need","remaining":"Export"}"#)
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(result["error"] == .null)
        #expect(result["recall_proposal"]["index"]["status"].string == "off")
        #expect(!text.contains("profileDoesNotReadMemory"))
        await RecallLifecycleTests.close(session)
    }
}

extension SessionProfileRuntimeTests {
    @Test func defaultDefinitionsFollowTheDispatcherAfterChannelsLoad() async throws {
        let session = P.photoSession(try W.directory())
        for surface in ["v1", "v2"] {
            for cycle in ["v1", "v2"] {
                await SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": surface, "task_cycle": cycle])) {
                    let tools = AutomationTools(session: session, channels: [.web, .adapters])
                    #expect(tools.toolDefinitions == tools.dispatcher.toolDefinitions)
                    tools.adapters = nil
                    tools.router = nil
                    #expect(tools.toolDefinitions == tools.dispatcher.toolDefinitions)
                    await tools.afterTurn()
                    #expect(tools.toolDefinitions == tools.dispatcher.toolDefinitions)
                }
            }
        }
        await RecallLifecycleTests.close(session)
    }
}

extension SessionProfileRuntimeTests {
    @Test func offMemoryScopeReachesNewRecorderTasks() async throws {
        let memory = try W.service()
        let access = SessionProfile.cli.replacing(memory: .off).memoryAccess
        await MemoryAccess.$current.withValue(access) {
            let work = Task {
                let recorder = CallRecorder(memory: memory, brain: W.brain(memory),
                    context: ActionContext(source: .cli, streamID: "juniper"))
                #expect(await recorder.access == access)
                _ = await recorder.observe(W.window([W.open]))
            }
            await work.value
        }
        #expect(await memory.flush(within: .seconds(10)))
        let count = try await memory.perform { repositories in
            try await repositories.store.read { handle in
                try handle.query("SELECT count(*) FROM brain_scenes", []) { $0.integer(0) ?? 0 }.first
            }
        }
        #expect(count == 0)
        await memory.close()
    }
}
