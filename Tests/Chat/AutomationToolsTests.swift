import AppKit
@testable import AutomationMCP
import AutomationRuntime
import Capabilities
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing

@Suite("Automation MCP application boundary")
struct AutomationToolsTests {
    @Test func instructionsUseStructuredPreturnAndTheTaskCycle() {
        for channels: AutomationChannels in [[], [.native], [.web], [.adapters], .all] {
            let text = AutomationTools.instructions(for: channels)

            #expect(!text.contains("call status and observe"))
            #expect(!text.contains("windows, then open_session"))
            #expect(text.contains("plan") && text.contains("end"))
        }
    }

    @Test("served and discoverable tools declare interruption policy")
    @MainActor
    func interruptionClassification() {
        let definitions = AutomationTools.definitions(for: .all)
        #expect(definitions.compactMap { $0["name"].string } == ToolList.core.map(\.rawValue))
        for tool in definitions {
            let name = tool["name"].string ?? ""
            #expect((AutomationTools.interruptionPolicy(for: name) == .readOnly)
                == (tool["annotations"]["readOnlyHint"].bool == true))
        }
        for name in ["status", "windows", "apps", "observe", "app_capabilities", "find"] {
            #expect(AutomationTools.interruptionPolicy(for: name) == .readOnly)
        }
        for name in ["act", "select", "type_text", "insert_text", "press_key", "scroll", "drag",
                     "context_menu", "batch", "menu", "press", "app_call", "close_session", "plan", "end", "call"] {
            #expect(AutomationTools.interruptionPolicy(for: name) == .mutating)
        }
        #expect(AutomationTools.interruptionPolicy(for: "open_session") == .openingScene)
        #expect(AutomationTools.interruptionPolicy(for: "unknown") == .mutating)
    }

    @Test(arguments: ["open_session", "observe", "act", "type_text", "press_key", "menu",
                      "batch", "plan", "end", "find", "call", "unknown"])
    func interruptionClassKeepsTaskWritersOutOfHumanReadWork(_ name: String) {
        let expected: AutomationTools.InterruptionPolicy = name == "open_session" ? .openingScene
            : ["observe", "find"].contains(name) ? .readOnly : .mutating
        #expect(AutomationTools.interruptionPolicy(for: name) == expected)
    }

    @Test @MainActor func planChangesTaskStateButDoesNotGrantApplicationEffects() throws {
        let contract = try #require(ToolCatalogue.contracts(for: []).first { $0.id.rawValue == "plan" })
        #expect(contract.effect == .read)
        #expect(contract.interruption == .mutating)
        #expect(!contract.parallelSafe)
        let definition = try #require(AutomationTools.definitions.first { $0["name"].string == "plan" })
        #expect(definition["annotations"]["readOnlyHint"] == .bool(false))
    }

    @Test("shortcut guidance preserves target-specific support and observed file-panel state")
    func shortcutGuidanceMatchesQualifiedTargets() {
        let instructions = ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.5"))
        #expect(!instructions.contains("Command-C, Command-V, Command-A, Command-Z) do nothing"))
        #expect(instructions.contains("Shortcut support depends on the target and its current context"))
        #expect(instructions.contains("never automatically replay an action that may already have happened"))
        #expect(instructions.contains("observe its initial value"))
        #expect(!instructions.contains("Go to Folder opens with / in its field"))
    }

    @Test("the instructions say that document apps save an edit by themselves, and how a panel's Go to Folder takes a path")
    func autosaveAndPanelPathGuidance() {
        let instructions = ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.5"))
        #expect(instructions.contains("save an edit into the open file by themselves, without Save"))
        #expect(instructions.contains("the copy where the person asked (File > Save As, its name and its folder)"))
        #expect(instructions.contains("If the copy cannot be saved there, edit nothing and say so"))
        #expect(instructions.contains("\"Keep changes in original document\""))
        #expect(instructions.contains("File > Revert To > Last Opened"))
        #expect(instructions.contains("otherwise say that it holds the edit"))
        #expect(instructions.contains("enter the path with insert_text"))
    }

    @Test("a target copied with the scene's id mark names the element by its id; any other target is kept as written")
    func elementReferenceOfACopiedMark() async throws {
        #expect(AutomationTools.elementReference("Text field id:'control|textfield'") == "control|textfield")
        #expect(AutomationTools.elementReference("id:'control|textfield'") == "control|textfield")
        #expect(AutomationTools.elementReference("  [field] Name id:'control|name'  ") == "control|name")
        #expect(AutomationTools.elementReference("id:'?|@4,0'") == "?|@4,0")
        #expect(AutomationTools.elementReference("Text field") == "Text field")
        #expect(AutomationTools.elementReference("control|textfield") == "control|textfield")
        #expect(AutomationTools.elementReference("Paid:'yes'") == "Paid:'yes'", "a label that only ends like a mark is kept")
        #expect(AutomationTools.elementReference("id:''") == "id:''")

        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id).uuidString
        _ = try await tools.boundaryCall("act", .object(["target": .string("Salva id:'control|salva'")]))
        _ = try await tools.boundaryCall("type_text", .object([
            "target": .string("id:'control|textfield'"), "text": .string("campione")
        ]))
        _ = try await tools.boundaryCall("act", .object(["target": .string("Annulla")]))
        #expect(session.calls.contains("control|salva"))
        #expect(session.calls.contains("Annulla"))
        guard case .typeText(_, let field, _)? = session.inputs.first else {
            Issue.record("type_text delivered no input: \(session.inputs)")
            return
        }
        #expect(field == "control|textfield")
    }

    @Test("opening distinguishes an explicitly named application from a generic request")
    func namedMeansTheAppOrItsBrand() throws {
        let definition = try #require(AutomationTools.definitions(for: .web).first { $0["name"].string == "open_session" })
        let named = definition["inputSchema"]["properties"]["named"]
        #expect(named["type"].string == "boolean")
        #expect(named["description"].string?.contains("person") == true)
        #expect(definition["description"].string?.contains("explicitly named") == true)
    }

    @Test("instructions describe only composed routes while the opening contract stays compact")
    func instructionsFollowTheChannels() throws {
        let seatOnly = "All app actions happen on a background Seat."
        let browserApps = "For anything on the web, use the browser apps marks as the default"
        let native = "A native app is driven where it is, in the background behind the person's windows (the "
            + "MacDriver); when the MacDriver gives it back, it moves to a background Seat."
        let seat = AutomationTools.instructions(for: [])
        #expect(seat == AutomationTools.instructions)
        #expect(seat.contains(seatOnly) && seat.contains(browserApps) && !seat.contains("web:<host>"))
        for channels: AutomationChannels in [[.native], [.web], [.native, .web], .all] {
            let text = AutomationTools.instructions(for: channels)
            #expect(!text.contains(seatOnly))
            #expect(text.contains(native) == channels.contains(.native))
            #expect(text.contains("A web page opens in Braus's own browser engine") == channels.contains(.web))
            #expect(text.contains(browserApps) != channels.contains(.web))
            let opening = try #require(AutomationTools.definitions(for: channels).first { $0["name"].string == "open_session" })
            #expect(opening["description"].string?.contains("Returns the current scene") == true)
        }
        let tools = AutomationTools(session: SyntheticSession(), channels: [.native, .web])
        #expect(tools.instructions == AutomationTools.instructions(for: [.native, .web]))
        #expect(AutomationTools(session: SyntheticSession()).instructions == AutomationTools.instructions)
    }

    @Test("the initial core is stable while discovery follows composed channels")
    func channelsDecideTheTools() throws {
        func discovered(_ channels: AutomationChannels) -> Set<String> {
            Set(ToolCatalogue.availableDefinitions(for: channels).compactMap { $0["name"].string })
        }
        let core = ToolList.core.map(\.rawValue)
        for channels: AutomationChannels in [[], [.native], [.web], [.adapters], .all] {
            #expect(AutomationTools.definitions(for: channels).compactMap { $0["name"].string } == core)
        }
        #expect(discovered([]).isDisjoint(with: ["app_capabilities", "app_call", "collect_posts"]))
        #expect(discovered(.adapters).subtracting(discovered([])) == ["app_capabilities", "app_call"])
        #expect(discovered(.web).subtracting(discovered([])) == ["collect_posts"])
        let tools = AutomationTools(session: SyntheticSession())
        #expect(tools.adapters == nil && tools.router == nil)
        let routed = AutomationTools(session: SyntheticSession(), channels: [.web, .adapters])
        #expect(routed.adapters != nil && routed.router != nil)
        #expect(routed.toolDefinitions.compactMap { $0["name"].string } == core)
        #expect(routed.toolDefinitions.compactMap { $0["name"].string } == core)
        #expect(!routed.groupIndex.isEmpty)
    }

    @Test("an adapter tool in a composition without adapters is refused and touches no session")
    func adapterToolsNeedTheirChannel() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        await #expect(throws: AutomationFailure.self) {
            _ = try await tools.boundaryCall("app_call", .object(["app": .string("Notes"), "verb": .string("notes.list")]))
        }
        #expect(session.calls.isEmpty)
    }

    @Test("channels parse from a list, all or none, and a word that is not a channel is refused")
    func channelsParse() throws {
        #expect(try AutomationChannels(parsing: "") == [])
        #expect(try AutomationChannels(parsing: "none") == [])
        #expect(try AutomationChannels(parsing: " Native , web") == [.native, .web])
        #expect(try AutomationChannels(parsing: "all") == .all)
        #expect(AutomationChannels.all.description == "native,web,adapters")
        #expect(throws: AutomationFailure.self) { try AutomationChannels(parsing: "native,wbe") }
        #expect(throws: AutomationFailure.self) { try AutomationChannels(parsing: "unsupported") }
    }

    @Test("exact native window titles distinguish an omitted selector from an untitled window")
    func nativeWindowTitleIsPreserved() async throws {
        let definition = try #require(AutomationTools.definitions.first { $0["name"].string == "open_session" })
        let titleSchema = definition["inputSchema"]["properties"]["window"]
        #expect(titleSchema["type"].string == "string")
        #expect(titleSchema["minLength"] == .null || titleSchema["minLength"] == .number(0))
        for title: String? in [nil, "", "  ", "Probe.png @ 100%"] {
            let session = SyntheticSession()
            session.id = nil
            let tools = AutomationTools(session: session)
            var arguments: [String: JSONValue] = ["app": .string("Synthetic Mixer")]
            if let title { arguments["window"] = .string(title) }
            _ = try await tools.boundaryCall("open_session", .object(arguments))
            #expect(session.openedWindowTitles == [title])
            #expect(session.calls == ["open"])
        }
    }

    @Test("non-string window selectors refuse before opening a session")
    func malformedWindowTitleCannotOpen() async throws {
        for title: JSONValue in [.null, .bool(true), .number(109442), .array([]), .object([:])] {
            let session = SyntheticSession()
            session.id = nil
            let tools = AutomationTools(session: session)
            await #expect(throws: AutomationFailure.self) {
                _ = try await tools.boundaryCall("open_session", .object([
                    "app": .string("Synthetic Mixer"), "window": title
                ]))
            }
            #expect(session.calls.isEmpty)
            #expect(session.id == nil)
        }
    }

    @Test("Observation guidance follows the remaining session, without replaying a terminal failure", arguments: [true, false])
    func observationGuidanceMatchesSessionLifetime(_ ends: Bool) async throws {
        let session = SyntheticSession()
        session.observationFailure = AutomationFailure("Synthetic observation refusal.")
        session.endsWhenObserved = ends
        let id = try #require(session.id)
        var records: [String] = []
        let tools = AutomationTools(session: session)
        tools.record = { records.append($0) }
        await #expect(throws: AutomationFailure.self) {
            try await tools.boundaryCall("observe", .object([:]))
        }
        #expect(session.calls == ["observe"])
        let record = try #require(records.last)
        if ends {
            #expect(session.id == nil)
            #expect(!record.contains("Observe before any retry"))
            #expect(!record.contains("Use status"))
            #expect(record.contains("open_session"))
        } else {
            #expect(session.id == id)
            #expect(record.contains("Observe before any retry"))
        }
    }

    @Test("a scene the seat took without another window of the application carries its notice")
    func aSceneCarriesTheSeatNotice() async throws {
        let session = SyntheticSession()
        let id = try #require(session.id)
        var records: [String] = []
        let tools = AutomationTools(session: session)
        tools.record = { records.append($0) }

        _ = try await tools.boundaryCall("observe", .object([:]))
        #expect(records.last?.contains("\"notice\"") == false)

        session.seatNotice = "window 7 is on the person's screen"
        _ = try await tools.boundaryCall("observe", .object([:]))
        #expect(records.last?.contains("window 7 is on the person's screen") == true)
        _ = try await tools.boundaryCall("status", .object([:]))
        #expect(records.last?.contains("\"notice\"") == false, "only an answer with a scene carries it")
    }

    @Test("a page in the person's own Chrome says so under browser in each answer with a scene, beside the seat's")
    func aSceneCarriesTheBrowserNotice() async throws {
        let session = SyntheticSession()
        let id = try #require(session.id)
        var records: [String] = []
        let tools = AutomationTools(session: session)
        tools.record = { records.append($0) }

        _ = try await tools.boundaryCall("observe", .object([:]))
        #expect(records.last?.contains("\"browser\"") == false)

        session.browserNotice = "This page is in the person's own Chrome"
        session.seatNotice    = "window 7 is on the person's screen"
        _ = try await tools.boundaryCall("observe", .object([:]))
        let answer = try #require(records.last)
        #expect(answer.contains("\"browser\"") && answer.contains("This page is in the person's own Chrome"))
        #expect(answer.contains("window 7 is on the person's screen"), "the seat's notice is kept")
        _ = try await tools.boundaryCall("status", .object([:]))
        #expect(records.last?.contains("\"browser\"") == false, "only an answer with a scene carries it")
    }

    @Test func aStaleArgumentCannotSelectAnotherSession() async throws {
        let session = SyntheticSession()
        let current = session.id
        let tools = AutomationTools(session: session)
        await #expect(throws: AutomationFailure.self) {
            try await tools.boundaryCall("act", .object(["session": .string("old"), "target": .string("Create")]))
        }
        #expect(session.calls.isEmpty && session.id == current)
        _ = try await tools.boundaryCall("act", .object(["target": .string("Create")]))
        #expect(session.calls == ["Create"])
        session.id = nil
        await #expect(throws: AutomationFailure.self) {
            try await tools.boundaryCall("act", .object(["target": .string("Create")]))
        }
        #expect(session.calls == ["Create"], "a closed session is not reopened implicitly")
    }

    @Test("a reconnected client operates only its own session and rejects stale arguments")
    func reconnectKeepsSessionOwnership() async throws {
        let before = SyntheticSession()
        let old = try #require(before.id).uuidString
        await before.close()
        let after = SyntheticSession()
        let current = after.id
        let tools = AutomationTools(session: after)
        #expect(current?.uuidString != old)
        await #expect(throws: AutomationFailure.self) {
            try await tools.boundaryCall("act", .object(["session": .string(old), "target": .string("Create")]))
        }
        #expect(after.calls.isEmpty)
        _ = try await tools.boundaryCall("act", .object(["target": .string("Create")]))
        #expect(before.calls == ["close"] && before.id == nil)
        #expect(after.calls == ["Create"] && after.id == current)
    }

    @Test("a malformed later batch routing field or argument never reads or changes the app")
    func invalidBatchRowsHaveNoEffects() async throws {
        for bad: JSONValue in [.object(["step": .number(1)]), .object(["step": .string("r0")]),
                               .object(["step": .string("r01")]), .object(["step": .string("r2")]), .object(["target": .number(1)])] {
            let session = SyntheticSession()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            session.memoryDirectory = directory
            let tools = AutomationTools(session: session)
            let declared = try await tools.call("plan", .object(["request": .string("Validate all batch rows before acting"),
                "rows": .array([.object(["title": .string("Exercise the synthetic controls")])])]))
            try #require(declared["isError"].bool != true && tools.openTask != nil)
            session.calls.removeAll()
            var invalid: [String: JSONValue] = ["operation": .string("act"), "target": .string("Toggle"), "step": .string("r1")]
            invalid.merge(try #require(bad.object), uniquingKeysWith: { _, new in new })
            await #expect(throws: AutomationFailure.self) {
                try await tools.boundaryCall("batch", .object(["steps": .array([
                    .object(["operation": .string("act"), "target": .string("Create"), "step": .string("r1")]),
                    .object(invalid)
                ])]))
            }
            #expect(session.calls.isEmpty && session.inputs.isEmpty)
        }
    }

    @Test
    func malformedLaterBatchStepPreventsEveryEffect() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        do {
            _ = try await tools.boundaryCall("batch", .object([
                "steps": .array([
                    .object(["operation": .string("act"), "target": .string("Create")]),
                    .object(["operation": .string("act"), "target": .string("Toggle"),
                             "verb": .string("set_toggle")])
                ])
            ]))
            Issue.record("Malformed batch accepted.")
        } catch { #expect(session.calls.isEmpty) }
    }

    @Test
    func batchStopsOnUnknownWhenTheNextTargetDisappears() async throws {
        let session = SyntheticSession()
        session.results = [.foundActed, .actedUnverified, .foundActed]
        session.removesTargetsWhenUnverified = true
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.boundaryCall("batch", .object([
            "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls.filter { $0 != "observe" } == ["First", "Second"])
        #expect(result.boundaryPayload["status"].string == "stopped")
        #expect(result.boundaryPayload["attemptedSteps"] == .number(2))
        #expect(result.boundaryPayload["verifiedSteps"] == .number(1))
    }

    @Test func anUnknownEffectCanContinueToAnAvailableNextTargetWithoutReplay() async throws {
        let session = SyntheticSession()
        session.results = [.foundActed, .actedUnverified, .foundActed]
        let result = try await AutomationTools(session: session).boundaryCall("batch", .object([
            "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls.filter { $0 != "observe" } == ["First", "Second", "Third"])
        #expect(result.boundaryPayload["status"].string == "completed")
        #expect(result.boundaryPayload["attemptedSteps"] == .number(3))
        #expect(result.boundaryPayload["verifiedSteps"] == .number(2))
    }

    @Test func discoveredToolsRequireDelegation() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("status", .object([:]))
        }
        #expect(session.calls.isEmpty)
        _ = try await tools.boundaryCall("status", .object([:]))
        #expect(session.calls.isEmpty, "delegated status reads the host, never performs an application gesture")
    }

    @Test
    func thrownBatchFailureKeepsEarlierResults() async throws {
        let session = SyntheticSession()
        session.throwOnTarget = "Second"
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.boundaryCall("batch", .object([
            "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls.filter { $0 != "observe" } == ["First", "Second"])
        #expect(result.boundaryPayload["verifiedSteps"] == .number(1))
        #expect(result.boundaryPayload["status"].string == "stopped")
        #expect(result.boundaryPayload["attemptedSteps"] == .number(2))
        #expect(result.boundaryPayload["message"].string?.contains("error") == true)
    }

    @Test("A terminal batch failure keeps prior effects and never advises observing its ended ID")
    func aTerminalBatchFailureNeedsDiscovery() async throws {
        let session = SyntheticSession()
        session.throwOnTarget = "Second"
        session.endsWhenActFails = true
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.boundaryCall("batch", .object([
            "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls.filter { $0 != "observe" } == ["First", "Second"])
        #expect(session.id == nil)
        #expect(result.boundaryPayload["verifiedSteps"] == .number(1))
        #expect(result.boundaryPayload["status"].string == "stopped")
        #expect(result.boundaryPayload["attemptedSteps"] == .number(2))
        #expect(result.boundaryPayload["observation"] == .null)
        #expect(!session.calls.dropFirst().contains("Third"))
    }

    @Test
    func separateToolCallsBorrowOneSessionUntilExplicitClose() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let arguments = JSONValue.object([:])
        _ = try await tools.boundaryCall("observe", arguments)
        _ = try await tools.boundaryCall("observe", arguments)
        #expect(session.id == id)
        #expect(session.calls == ["observe", "observe"])
        _ = try await tools.boundaryCall("close_session", arguments)
        #expect(session.id == nil)
        #expect(session.calls.last == "close")
    }

    @Test
    func closingReportsPendingApplicationCleanupAlongsideTheReleasedSeat() async throws {
        let session = SyntheticSession()
        let warning = "TextEdit is still running after the quit request."
        session.closeWarning = warning
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.boundaryCall("close_session", .object([:]))

        #expect(session.id == nil)
        #expect(result.boundaryPayload["status"].string == "closed")
        #expect(result.boundaryPayload["warning"].string == warning)
    }

    @Test
    func windowsUsesTheSessionsDiscoveryWithoutOpeningASeat() async throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let session = SyntheticSession()
        session.discoveryRows = [WindowRow(layer: 0, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                           title: "Owned offscreen fixture", number: 987_654)]
        let result = try await AutomationTools(session: session).boundaryCall("windows", .object([
            "app": .string("com.apple.finder")
        ]))
        #expect(session.discoveryReads == [finder.processIdentifier])
        #expect(session.calls.isEmpty)
        #expect(result.boundaryPayload["applications"].array?.first?["windows"] == .array([
            .object(["id": .number(987_654), "title": .string("Owned offscreen fixture")])
        ]))
    }

    @Test func initialAndDiscoveredInputSchemasUseTheCurrentSession() throws {
        let tools = Dictionary(uniqueKeysWithValues: ToolCatalogue.availableDefinitions(for: .all).map { ($0["name"].string ?? "", $0) })
        let required: [String: [String]] = [
            "type_text": ["target", "text"], "insert_text": ["text"], "press_key": ["key"],
            "scroll": ["direction"], "drag": ["from"], "context_menu": ["target", "item"],
            "menu": ["path"], "press": ["button"]
        ]
        for (name, fields) in required {
            let tool = try #require(tools[name], "missing tool \(name)")
            #expect(tool["inputSchema"]["required"].array?.compactMap(\.string) == fields)
            #expect(tool["inputSchema"]["properties"]["session"] == .null)
            #expect(tool["annotations"]["readOnlyHint"] == .bool(false))
        }
        let key = tools["press_key"]?["inputSchema"]["properties"]
        let names = key?["key"]["enum"].array?.compactMap(\.string) ?? []
        #expect(["return", "tab", "escape", "space", "delete", "left", "up", "a", "z", "0", "9"].allSatisfy(names.contains))
        #expect(key?["modifiers"]["items"]["enum"].array?.compactMap(\.string) == ["cmd", "shift", "opt", "ctrl"])
        #expect(key?["count"]["maximum"] == .number(Double(InputRequest.maximumKeyPresses)))
        let coreAct = try #require(AutomationTools.definitions.first { $0["name"].string == "act" })
        #expect(!(coreAct["inputSchema"]["properties"]["verb"]["enum"].array ?? []).contains(.string("triple_click")))
        let operations = tools["batch"]?["inputSchema"]["properties"]["steps"]["items"]["properties"]["operation"]["enum"].array
        #expect(operations?.compactMap(\.string) == ["act", "select", "type_text", "insert_text", "press_key", "scroll", "drag", "context_menu", "menu"])
        #expect(tools["batch"]?["inputSchema"]["properties"]["steps"]["maxItems"] == .number(20))
        #expect(AutomationTools.instructions.contains("may need explicit focus before accepting keys"))
        #expect(AutomationTools.instructions.contains("never one press_key per character"))
    }

    @Test
    func insertionPreservesTheExistingFocusWithoutATarget() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id).uuidString
        let result = try await tools.boundaryCall("insert_text", .object([
            "text": .string("Braus-à-中-🙂")
        ]))
        #expect(result.boundaryPayload["effect"].string == "confirmed")
        #expect(session.inputs.count == 1)
        #expect(session.inputs == [.insertText("Braus-à-中-🙂")])
        #expect(session.sections == [nil])
        _ = try await tools.boundaryCall("insert_text", .object([
            "text": .string("Braus"),
            "expected_value": .string("prefix Braus suffix")
        ]))
        #expect(session.inputs.last == .insertText("Braus", expecting: "prefix Braus suffix"))
    }

    @Test
    func inputToolsReachTheSessionAsEngineInputs() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id).uuidString
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
            try await tools.boundaryCall(name, .object(arguments))
        }
        let typed = try await call("type_text", ["target": .string("Project Name"), "text": .string("My Project")])
        #expect(typed.boundaryPayload["effect"].string == "confirmed")
        _ = try await call("type_text", ["target": .string("Notes"), "text": .string(" more"), "replace": .bool(false),
                                         "section": .string("Inspector")])
        _ = try await call("press_key", ["key": .string("n"), "modifiers": .array([.string("cmd"), .string("shift")]),
                                         "count": .number(2)])
        _ = try await call("press_key", ["key": .string("return")])
        _ = try await call("scroll", ["direction": .string("down")])
        _ = try await call("scroll", ["direction": .string("up"), "lines": .number(5), "target": .string("List")])
        _ = try await call("drag", ["from": .string("Clip"), "to": .string("Timeline")])
        _ = try await call("drag", ["from": .string("Clip"), "dx": .number(-40)])
        _ = try await call("context_menu", ["target": .string("Search"), "item": .string("Select All")])
        #expect(session.inputs == [
            .typeText("My Project", into: "Project Name", replacing: true),
            .typeText(" more", into: "Notes", replacing: false),
            .pressKey(KeyChord(.character("n"), modifiers: [.command, .shift]), times: 2),
            .pressKey(KeyChord(.return), times: 1),
            .scroll(lines: -3, over: nil),
            .scroll(lines: 5, over: "List"),
            .drag(from: "Clip", to: .target("Timeline")),
            .drag(from: "Clip", to: .offset(dx: -40, dy: 0)),
            .contextMenu(on: "Search", item: "Select All"),
        ])
        #expect(session.sections[1] == "Inspector")
    }

    @Test
    func malformedInputsNeverReachTheSession() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        let malformed: [(String, [String: JSONValue])] = [
            ("insert_text", ["text": .string("")]),
            ("insert_text", ["text": .string("x"), "target": .string("Name")]),
            ("insert_text", ["text": .string("x"), "expected_value": .bool(true)]),
            ("insert_text", ["text": .string("x"), "expected_value": .string("")]),
            ("press_key", ["key": .string("f13")]),
            ("press_key", ["key": .string("a"), "modifiers": .array([.string("hyper")])]),
            ("press_key", ["key": .string("a"), "count": .number(21)]),
            ("press_key", ["key": .string("a"), "count": .number(1.5)]),
            ("scroll", ["direction": .string("left")]),
            ("drag", ["from": .string("Clip")]),
            ("drag", ["from": .string("Clip"), "to": .string("Bin"), "dx": .number(3)]),
            ("type_text", ["target": .string("Name"), "text": .string("x"), "replace": .string("yes")]),
            ("context_menu", ["target": .string("Search")]),
        ]
        for (name, arguments) in malformed {
            do {
                _ = try await tools.boundaryCall(name, .object(arguments))
                Issue.record("\(name) accepted \(arguments)")
            } catch {}
        }
        #expect(session.calls.isEmpty)
    }

    @Test
    func batchStopsBeforeReturnWhenInsertionIsUnverified() async throws {
        let session = SyntheticSession()
        session.results = [.actedUnverified, .foundActed]
        let result = try await AutomationTools(session: session).boundaryCall("batch", .object([
            "steps": .array([
                .object(["operation": .string("insert_text"), "text": .string("Braus")]),
                .object(["operation": .string("press_key"), "key": .string("return"),
                         "expect": .object(["window": .string(session.scene.windowTitle)])])
            ])
        ]))
        #expect(session.inputs == [.insertText("Braus")])
        #expect(result.boundaryPayload["status"].string == "stopped")
        #expect(result.boundaryPayload["attemptedSteps"] == .number(1))
        #expect(result.boundaryPayload["verifiedSteps"] == .number(0))
    }

    @Test func aCommittingKeyBeforeTheLastPositionRefusesTheWholeBatch() async throws {
        let session = SyntheticSession()
        let result = try await AutomationTools(session: session).boundaryCall("batch", .object([
            "steps": .array([
                .object(["operation": .string("type_text"), "target": .string("Name"), "text": .string("Demo")]),
                .object(["operation": .string("press_key"), "key": .string("return")]),
                .object(["operation": .string("scroll"), "direction": .string("down")])
            ])
        ]))
        #expect(session.inputs.isEmpty)
        #expect(result.boundaryPayload["status"].string == "stopped")
        #expect(result.boundaryPayload["attemptedSteps"] == .number(0))
        #expect(result.boundaryPayload["verifiedSteps"] == .number(0))
        #expect(result.boundaryPayload["message"].string?.contains("committing_not_last") == true)
    }
}

extension AutomationToolsTests {
    @Test("open_session and the instructions teach web addresses only where the web is offered")
    func webIsTaughtOnlyWhereOffered() throws {
        func opening(_ offered: Bool) -> String {
            AutomationTools.definitions(offeringAdapters: false, offeringWeb: offered)
                .first { $0["name"].string == "open_session" }?["description"].string ?? ""
        }
        #expect(!opening(false).contains("web:<host>"))
        #expect(opening(true).contains("Returns the current scene"))
        #expect(!AutomationTools.instructions.contains("web:<host>"))
        let web = AutomationTools.instructions(offeringAdapters: false, offeringWeb: true)
        #expect(web.contains("call open_session with web:<host> or an http(s) address"))
        #expect(web.contains("page\'s URL"))
        #expect(!web.contains("use the browser apps marks as the default"))
        let tools = AutomationTools(session: SyntheticSession(), offersWeb: true)
        #expect(tools.toolDefinitions == AutomationTools.definitions(offeringAdapters: false, offeringWeb: true))
        #expect(tools.instructions == AutomationTools.instructions(offeringAdapters: false, offeringWeb: true))
    }

    @Test func appsIsDiscoveredReadOnlyWithAnOptionalQuery() throws {
        #expect(!AutomationTools.definitions.contains { $0["name"].string == "apps" })
        let apps = try #require(ToolCatalogue.availableDefinitions(for: []).first { $0["name"].string == "apps" })
        #expect(apps["annotations"]["readOnlyHint"] == .bool(true))
        #expect(apps["inputSchema"]["required"] == .array([]))
        #expect(apps["inputSchema"]["properties"].object?.keys.sorted() == ["query"])
        #expect(apps["description"].string?.isEmpty == false)
    }

    @Test
    func appsMarksTheDefaultBrowserAndOnlyIt() async throws {
        let session = CatalogueSession(candidates: [
            ApplicationCandidate(name: "Browser", bundleID: "com.example.Browser", version: "1.0", isRunning: true,
                                 isDefaultBrowser: true),
            ApplicationCandidate(name: "Other Browser", bundleID: "com.example.Other", version: nil, isRunning: true)
        ])
        let result = try await AutomationTools(session: session).boundaryCall("apps", .null)
        #expect(result.boundaryPayload == .object(["applications": .array([
            .object(["name": .string("Browser"), "bundleID": .string("com.example.Browser"),
                     "version": .string("1.0"), "running": .bool(true), "defaultBrowser": .bool(true)]),
            .object(["name": .string("Other Browser"), "bundleID": .string("com.example.Other"),
                     "running": .bool(true)])
        ])]))
    }

    @Test
    func appsNeedsNoSessionAndReturnsTheCandidatesFields() async throws {
        let session = CatalogueSession(candidates: [
            ApplicationCandidate(name: "Pro Tools", bundleID: "com.avid.ProTools", version: "26.4.1.179",
                                 isRunning: false),
            ApplicationCandidate(name: "Pro Tools", bundleID: "com.example.ProTools", version: nil, isRunning: true,
                                 location: "~/Applications")
        ])
        let tools = AutomationTools(session: session)
        var records: [String] = []
        tools.record = { records.append($0) }
        let result = try await tools.boundaryCall("apps", .object(["query": .string("pro tools")]))
        #expect(session.queries == ["pro tools"])
        #expect(result.boundaryPayload == .object(["applications": .array([
            .object(["name": .string("Pro Tools"), "bundleID": .string("com.avid.ProTools"),
                     "version": .string("26.4.1.179"), "running": .bool(false)]),
            .object(["name": .string("Pro Tools"), "bundleID": .string("com.example.ProTools"),
                     "running": .bool(true), "location": .string("~/Applications")])
        ])]))
        #expect(records.first?.hasPrefix("→ apps ") == true)
        #expect(records.last?.hasPrefix("← apps ") == true)

        _ = try await tools.boundaryCall("apps", .null)
        #expect(session.queries == ["pro tools", nil])
    }

    @Test
    func appsListsSixtyAndCountsTheRest() async throws {
        let many = (1...61).map { ApplicationCandidate(name: "App \($0)", bundleID: "com.example.\($0)", version: nil,
                                                       isRunning: false) }
        let result = try await AutomationTools(session: CatalogueSession(candidates: many)).boundaryCall("apps", .null)
        #expect(result.boundaryPayload["applications"].array?.count == 60)
        #expect(result.boundaryPayload["more"] == .string("1 more not listed; pass a query to find them."))
    }

    @Test
    func theDefaultListsRunningApplicationsOnly() async throws {
        let listed = try await SyntheticSession().applications(matching: nil)
        #expect(!listed.isEmpty)
        #expect(listed.allSatisfy { app in
            app.isRunning && NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                .contains { $0.activationPolicy == .regular }
        })
        let finder = try await SyntheticSession().applications(matching: "com.apple.FINDER")
        #expect(finder.map(\.bundleID) == ["com.apple.finder"])
    }
}

extension AutomationToolsTests {
    /// A window titled `title` whose one section lists a control for each of `rows`.
    private static func scene(_ rows: [String], title: String = "Synthetic New Paths") -> SceneSnapshot {
        SceneSnapshot(
            bundleID         : "test.synthetic",
            appName          : "Synthetic Mixer",
            windowTitle      : title,
            viewportPixelSize: ViewportPixelSize(width: 400, height: 200),
            elements         : rows.enumerated().map { index, label in
                SceneElement(id: "row\(index)", kind: .control, label: label,
                             bounds: NormalizedRect(x: 0.1, y: 0.04 * Double(index), width: 0.2, height: 0.03),
                             section: "Tracks")
            },
            sections         : [SceneSection(name: "Tracks",
                                             bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1))]
        )
    }

    private static let rows = (1...20).map { "Track \($0) volume" }

    @Test
    func anActionSendsOnlyTheChangesSinceTheSceneTheModelRead() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        let observed = try await tools.boundaryCall("observe", .object([:])).boundaryPayload
        #expect(observed["scene"].string == session.scene.text(cuts: .safe))
        #expect(observed["changes"] == .null)

        session.scene = Self.scene(Self.rows.map { $0 == "Track 7 volume" ? "Track 7 muted" : $0 })
        let acted = try await tools.boundaryCall("act", .object(["target": .string("Track 7")]))
        #expect(acted["structuredContent"] != .null)
        let observation = acted.boundaryPayload["observation"]
        let changes = try #require(observation["changes"].string)
        #expect(observation["scene"] == .null)
        #expect(observation["since"] == observed["revision"])
        #expect(changes.hasPrefix("r2 since r1\n## Tracks @0,0 100x100\n"))
        #expect(changes.contains("\n~ [control] Track 7 muted @10,24  (was label \"Track 7 volume\")"))
        #expect(!changes.contains("Track 8"))
        // Diagnostic envelopes retain identity; the nested model scene does not repeat it or its time.
        #expect(acted.boundaryPayload["session"] == id)
        #expect(observation["session"] == .null)
        #expect(observation["observedAt"] == .null)
        #expect(observed["session"] == id)
        #expect(observed["observedAt"].string != nil)

        #expect(observation["revision"] == .number(2))
        let again = try await tools.boundaryCall("act", .object(["target": .string("Track 7")]))
        #expect(again.boundaryPayload["observation"]["changes"] == .string("r3 unchanged since r2"))
    }

    @Test("observe answers the changes since the model's scene of the window, or the whole scene when asked")
    func observeSendsChangesUnlessAskedForTheWholeScene() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        let first = try await tools.boundaryCall("observe", .object([:])).boundaryPayload
        #expect(first["scene"].string == session.scene.text(cuts: .safe))

        let polled = try await tools.boundaryCall("observe", .object([:])).boundaryPayload
        #expect(polled["changes"] == .string("r2 unchanged since r1"))
        #expect(polled["since"] == .number(1))
        #expect(polled["scene"] == .null)

        session.scene.elements[0].state = .on
        let changed = try await tools.boundaryCall("observe", .object([:])).boundaryPayload
        let stated = "~ [control] Track 1 volume [on] @10,0  (was no state)"
        #expect(changed["changes"].string?.contains(stated) == true)
        #expect(changed["since"] == .number(2))

        let whole = try await tools.boundaryCall("observe", .object(["full": .bool(true)])).boundaryPayload
        #expect(whole["scene"].string == session.scene.text(cuts: .safe))
        #expect(whole["changes"] == .null)
        let again = try await tools.boundaryCall("observe", .object(["full": .bool(false)])).boundaryPayload
        #expect(again["changes"] == .string("r5 unchanged since r4"))

        let calls = session.calls
        await #expect(throws: AutomationFailure.self) {
            try await tools.boundaryCall("observe", .object(["full": .string("yes")]))
        }
        #expect(session.calls == calls)
        let definition = try #require(AutomationTools.definitions.first { $0["name"].string == "observe" })
        // A container is accepted where a section is, and the parameter says so.
        let act = try #require(AutomationTools.definitions.first { $0["name"].string == "act" })
        #expect(act["inputSchema"]["properties"]["section"]["type"].string == "string")
        let opening = try #require(AutomationTools.definitions.first { $0["name"].string == "open_session" })
        #expect(opening["description"].string?.contains("current scene") == true)
        #expect(definition["description"].string?.contains("full=true") == true)
        #expect(definition["inputSchema"]["properties"]["full"]["type"] == .string("boolean"))
        #expect(definition["inputSchema"]["required"] == .array([]))
    }

    @Test("open_session sends its scene whole even when the model read that window before")
    func openingSendsTheWholeScene() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.boundaryCall("observe", .object([:]))
        let opened = try await tools.boundaryCall("open_session", .object(["app": .string("Synthetic Mixer")])).boundaryPayload
        #expect(opened["scene"].string == session.scene.text(cuts: .safe))
        #expect(opened["changes"] == .null)
    }

    @Test("returning from a dialog sends the changes since the model's last scene of the window under it",
          arguments: [Optional(31), nil])
    func eachWindowKeepsItsOwnBaseline(_ mainNumber: Int?) async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        let main = Self.scene(Self.rows)
        session.scene = main
        session.observedWindowNumber = mainNumber
        _ = try await tools.boundaryCall("observe", .object([:]))

        let dialog = Self.scene((1...12).map { "Option \($0)" }, title: "Rename Track")
        session.scene = dialog
        session.observedWindowNumber = mainNumber.map { $0 + 1 }
        let opened = try await tools.boundaryCall("act", .object(["target": .string("Rename")])).boundaryPayload
        #expect(opened["observation"]["scene"].string == dialog.text(cuts: .safe))

        // The dialog loses its title between two readings, as one did on Resolve; it is the same window.
        session.scene.windowTitle = ""
        let typed = try await tools.boundaryCall("act", .object(["target": .string("Name")])).boundaryPayload
        #expect(typed["observation"]["since"] == .number(2))
        #expect(typed["observation"]["changes"].string?.contains("window: Synthetic Mixer (test.synthetic)") == true)

        session.scene = Self.scene(Self.rows.map { $0 == "Track 7 volume" ? "Track 7 renamed" : $0 })
        session.observedWindowNumber = mainNumber
        let closed = try await tools.boundaryCall("act", .object(["target": .string("OK")])).boundaryPayload
        let changes = try #require(closed["observation"]["changes"].string)
        #expect(closed["observation"]["since"] == .number(1))
        #expect(changes.contains("~ [control] Track 7 renamed"))
        #expect(!changes.contains("Track 8"))
    }

    @Test("the number of windows remembered is bounded, the least recently read forgotten first")
    func baselinesAreBounded() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        for index in 0...8 {
            session.scene = Self.scene(Self.rows, title: "Window \(index)")
            _ = try await tools.boundaryCall("observe", .object([:]))
        }
        session.scene = Self.scene(Self.rows, title: "Window 8")
        #expect(try await tools.boundaryCall("observe", .object([:])).boundaryPayload["changes"]
            == .string("r10 unchanged since r9"))
        session.scene = Self.scene(Self.rows, title: "Window 0")
        #expect(try await tools.boundaryCall("observe", .object([:])).boundaryPayload["scene"].string
            == session.scene.text(cuts: .safe))
    }

    @Test("a call whose answer never reached the model leaves the baseline the model read")
    func aFailedCallKeepsTheBaseline() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.boundaryCall("observe", .object([:]))

        session.scene.elements[0].state = .on
        tools.record = { if $0.hasPrefix("← observe") { throw AutomationFailure("transcript unavailable") } }
        await #expect(throws: AutomationFailure.self) {
            try await tools.boundaryCall("observe", .object([:]))
        }
        tools.record = nil
        let next = try await tools.boundaryCall("observe", .object([:])).boundaryPayload
        #expect(next["since"] == .number(1))
        #expect(next["changes"].string?.contains("(was no state)") == true)
    }

    @Test("an action's scene of another window, or one that changed in most of its lines, is sent whole",
          arguments: [true, false])
    func anotherWindowOrALargeChangeSendsTheWholeScene(_ isAnotherWindow: Bool) async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.boundaryCall("observe", .object([:]))
        let after = isAnotherWindow ? Self.scene(Self.rows, title: "Another window")
            : Self.scene(Self.rows.map { $0 + " (soloed)" })
        session.scene = after
        let acted = try await tools.boundaryCall("act", .object(["target": .string("Track 1")]))
        #expect(acted.boundaryPayload["observation"]["scene"].string == after.text(cuts: .safe))
        #expect(acted.boundaryPayload["observation"]["changes"] == .null)
    }

    @Test
    func anActionAfterTheSceneIsForgottenSendsItWhole() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.boundaryCall("observe", .object([:]))

        tools.contextHolds(after: .compaction)
        let acted = try await tools.boundaryCall("act", .object(["target": .string("Track 1")]))
        #expect(acted.boundaryPayload["observation"]["scene"].string == session.scene.text(cuts: .safe))
        #expect(acted.boundaryPayload["observation"]["changes"] == .null)
    }

    @Test
    func closingTheSessionForgetsTheSceneTheModelRead() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.boundaryCall("observe", .object([:]))
        _ = try await tools.boundaryCall("close_session", .object([:]))
        // The synthetic session takes its old ID back: only a forgotten baseline makes this scene whole.
        session.id = id
        let acted = try await tools.boundaryCall("act", .object([
            "target": .string("Track 1")
        ]))
        #expect(acted.boundaryPayload["observation"]["scene"].string == session.scene.text(cuts: .safe))
        #expect(acted.boundaryPayload["observation"]["changes"] == .null)
    }
}

/// CatalogueSession answers only apps, with a fixed list, and has no session to open.
@MainActor
private final class CatalogueSession: AutomationSessionOperating {
    let id: UUID? = nil
    let candidates: [ApplicationCandidate]
    var queries: [String?] = []

    init(candidates: [ApplicationCandidate]) { self.candidates = candidates }

    func applications(matching query: String?) async throws -> [ApplicationCandidate] {
        queries.append(query)
        return candidates
    }

    func open(application: String, window: String?) async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func observe() async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("unused") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func close() async {}
}

/// SyntheticSession preserves call order and ID invalidation without touching a real application.
@MainActor
private final class SyntheticSession: AutomationSessionOperating {
    var memoryDirectory: URL?
    var id: UUID? = UUID()
    var closeWarning: String?
    var seatNotice: String?
    var browserNotice: String?
    var observedWindowNumber: Int?
    var calls: [String] = []
    var openedWindowTitles: [String?] = []
    var results: [ActOutcomeKind] = []
    var removesTargetsWhenUnverified = false
    var throwOnTarget: String?
    var observationFailure: AutomationFailure?
    var endsWhenObserved = false
    var endsWhenActFails = false
    var inputs: [InputRequest.Input] = []
    var sections: [String?] = []
    var discoveryRows: [WindowRow] = []
    var discoveryReads: [pid_t] = []
    var scene = SceneSnapshot(bundleID: "test.synthetic", appName: "Synthetic Mixer",
                              windowTitle: "Synthetic New Paths",
                              viewportPixelSize: ViewportPixelSize(width: 400, height: 200),
                              elements: ["First", "Second", "Third", "Create", "Toggle", "Name"].enumerated().map { index, name in
                                  SceneElement(id: "fixture-\(index)", kind: .control, label: name,
                                      bounds: NormalizedRect(x: 0.1, y: Double(index) * 0.1, width: 0.2, height: 0.05),
                                      role: name == "Name" ? "AXTextField" : "AXButton")
                              })

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        calls.append("open")
        openedWindowTitles.append(window)
        id = UUID()
        return scene
    }

    func observe() async throws -> SceneSnapshot {
        calls.append("observe")
        if let observationFailure {
            if endsWhenObserved { id = nil }
            throw observationFailure
        }
        return scene
    }

    func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] {
        discoveryReads.append(processID)
        return discoveryRows
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        calls.append(target)
        if target == throwOnTarget {
            if endsWhenActFails { id = nil }
            throw AutomationFailure("Synthetic transport failure after an earlier effect.")
        }
        let kind = results.isEmpty ? .foundActed : results.removeFirst()
        if kind == .actedUnverified && removesTargetsWhenUnverified { scene.elements = [] }
        return ActOutcome(kind, "synthetic result", scene: scene, check: proof(for: kind))
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        calls.append("select")
        return ActOutcome(.foundActed, "synthetic selection", scene: scene, check: proof(for: .foundActed))
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        calls.append("deliver")
        inputs.append(input)
        sections.append(section)
        let kind = results.isEmpty ? .foundActed : results.removeFirst()
        return ActOutcome(kind, "synthetic input", scene: scene, check: proof(for: kind))
    }

    private func proof(for kind: ActOutcomeKind) -> OperationCheck {
        OperationCheck(condition: .structuralEffect, method: .sceneDifference,
            verdict: kind == .foundActed ? .passed : .unknown, performed: .requested)
    }

    func close() async { calls.append("close"); id = nil }
}

@MainActor
struct NoSessionArgumentTests {
    @Test func implicitSessionCallsDoNotExposeTheirIdentity() async throws {
        let session = SyntheticSession()
        let result = try await AutomationTools(session: session).boundaryCall("observe", .object([:]))
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(text.contains("<scene>"))
        #expect(!text.contains(try #require(session.id).uuidString))
        #expect(session.calls == ["observe"])
    }

    @Test func currentSessionAndStaleArgument() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        var lines: [String] = []
        tools.record = { lines.append($0) }
        let result = try await tools.boundaryCall("observe", .object([:]))
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(text.contains("<scene>") && text.contains("\n"))
        #expect(!text.contains("\\n") && !text.contains("observedAt"))
        #expect(!text.contains(try #require(session.id).uuidString))
        #expect(lines.first == "→ observe {}")
        #expect(session.calls == ["observe"])
        for arguments: JSONValue in [.object(["session": .string("stale")]),
                                     .object(["session": .number(17)]), .object(["foo": .number(1)])] {
            await #expect(throws: AutomationFailure.self) {
                _ = try await tools.boundaryCall("observe", arguments)
            }
            #expect(session.calls == ["observe"], "unknown arguments cannot read or select a session")
        }
        session.id = nil
        do {
            _ = try await tools.boundaryCall("observe", .object([:]))
            Issue.record("An observation without a session was accepted")
        } catch {
            #expect((error as? AutomationFailure)?.cause == "no_session")
        }
    }

}

@MainActor
struct ToolDescriptionCeilingTests {
    @Test func servedDefinitions() throws {
        for tool in AutomationTools.definitions(for: [.native, .web, .adapters]) {
            let schema = String(decoding: try JSONValue.canonicalEncoder().encode(tool["inputSchema"]), as: UTF8.self)
            #expect((tool["description"].string ?? "").count + schema.count <= 4096,
                    "\(tool["name"]): definition exceeds ceiling")
            #expect(tool["inputSchema"]["properties"]["session"] == .null)
            #expect(!(tool["inputSchema"]["required"].array ?? []).contains(.string("session")))
        }
    }
}

@MainActor
struct SceneAsTextTests {
    @Test func realSceneLines() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let result = try await tools.boundaryCall("observe", .object([:]))
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(text.contains("<scene>\n"))
        #expect(text.contains(session.scene.text(cuts: .safe)))
        #expect(!text.contains("\\n"))
        #expect(!text.contains("observedAt"))
        #expect(result["structuredContent"]["scene"].string == session.scene.text(cuts: .safe))
    }
}

@MainActor
struct BatchSurfaceDispatchTests {
    @Test func stopsAfterTheSecondStepWhenTheNextTargetIsUnavailable() async throws {
        let session = SyntheticSession()
        session.results = [.foundActed, .actedUnverified]
        session.removesTargetsWhenUnverified = true
        let tools = AutomationTools(session: session)
        let steps: [JSONValue] = ["First", "Second", "Third"].map {
            .object(["operation": .string("act"), "target": .string($0)])
        }
        let answer = try await tools.boundaryCall("batch", .object(["steps": .array(steps)]))
        let text = try #require(answer["content"].array?.first?["text"].string)
        #expect(session.calls.filter { $0 != "observe" } == ["First", "Second"])
        #expect(answer.boundaryPayload["status"].string == "stopped")
        #expect(answer.boundaryPayload["attemptedSteps"] == .number(2))
        #expect(answer.boundaryPayload["verifiedSteps"] == .number(1))
        #expect(answer.boundaryPayload["requested"] == .number(3))
        #expect(text.contains(" · "))
        #expect(answer.boundaryPayload["message"].string?.contains("unknown_without_next_target") == true)
    }
}


extension AutomationToolsTests {
    @Test
    @MainActor
    func safeSceneTextIsTheOrdinaryRenderer() async throws {
        let session = SyntheticSession()
        session.scene.elements = [SceneElement(
            id: "field", kind: .control, label: "Folder A",
            bounds: NormalizedRect(x: 0.1, y: 0.2, width: 0.2, height: 0.03),
            role: "AXTextField", value: "abcdef", selectedRange: NSRange(location: 3, length: 0)
        ), SceneElement(id: "caption", kind: .text, label: String(repeating: "Folder B ", count: 50),
            bounds: NormalizedRect(x: 0.1, y: 0.5, width: 0.2, height: 0.03))]
        session.scene.elements += (0..<12).map { index in
            SceneElement(id: "unchanged-\(index)", kind: .control, label: "Unchanged setting \(index)",
                bounds: .init(x: 0.5, y: Double(index) / 20, width: 0.4, height: 0.03))
        }
        let policy = SceneTextPolicy()
        let shown = ValueMinimization()
        let first = await policy.answer(session.scene, session: session, shown: shown).observation(nested: false)
        #expect(first["scene"].string == session.scene.text(cuts: .safe))
        let before = session.scene
        session.scene.elements[0].selectedRange = NSRange(location: 4, length: 0)
        let next = await policy.answer(session.scene, changesOnly: true, session: session, shown: shown).observation(nested: false)
        #expect(next["since"] == .number(1))
        #expect(before.text(cuts: .safe) == session.scene.text(cuts: .safe))
        #expect(SceneChanges.changes(from: before, to: session.scene, cuts: .safe).isEmpty)
        #expect(next["changes"] == .string("r2 unchanged since r1"))
    }
}

private extension JSONValue {
    var boundaryPayload: JSONValue {
        self["structuredContent"] != .null ? self["structuredContent"] : payload
    }
}

@MainActor
private extension AutomationTools {
    func boundaryCall(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        if ToolList.core.contains(where: { $0.rawValue == name }) { return try await call(name, arguments) }
        return try await call("call", .object(["name": .string(name),
            "arguments": arguments == .null ? .object([:]) : arguments]))
    }
}


extension AutomationToolsTests {
    @Test @MainActor func firstBatchDeliversItsWholeSceneWithoutHiddenBaselines() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let result = try await tools.boundaryCall("batch", .object(["steps": .array([
            .object(["operation": .string("act"), "target": .string("First")]),
            .object(["operation": .string("act"), "target": .string("Second")])])]))
        let observation = result.boundaryPayload["observation"]
        #expect(result.boundaryPayload["status"].string == "completed")
        #expect(session.calls.filter { $0 != "observe" } == ["First", "Second"])
        #expect(observation["revision"] == .number(1))
        #expect(observation["scene"].string == session.scene.text(cuts: .safe))
        #expect(observation["changes"] == .null && observation["since"] == .null)
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(text.contains(session.scene.text(cuts: .safe)))
        #expect(!text.contains("unchanged since"))
    }

    @Test @MainActor func batchDifferencesUseOnlyTheLastDeliveredScene() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let first = try await tools.boundaryCall("observe", .object([:])).boundaryPayload
        #expect(first["revision"] == .number(1) && first["scene"].string != nil)
        session.scene.elements[0].value = "batch-updated-value"
        let result = try await tools.boundaryCall("batch", .object(["steps": .array([
            .object(["operation": .string("act"), "target": .string("First")]),
            .object(["operation": .string("act"), "target": .string("Second")])])]))
        let observation = result.boundaryPayload["observation"]
        #expect(result.boundaryPayload["status"].string == "completed")
        #expect(session.calls.filter { $0 != "observe" } == ["First", "Second"])
        #expect(observation["revision"] == .number(2))
        #expect(observation["since"] == first["revision"])
        let changes = try #require(observation["changes"].string)
        #expect(changes.hasPrefix("r2 since r1\n"))
        #expect(changes.contains("batch-updated-value"))
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(text.contains(changes))
    }
}
