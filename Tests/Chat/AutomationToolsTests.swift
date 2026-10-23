import AppKit
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing

@Suite("Automation MCP application boundary")
struct AutomationToolsTests {
    @Test("shortcut guidance preserves target-specific support and observed file-panel state")
    func shortcutGuidanceMatchesQualifiedTargets() {
        let instructions = AutomationTools.instructions
        #expect(!instructions.contains("Command-C, Command-V, Command-A, Command-Z) do nothing"))
        #expect(instructions.contains("Shortcut support depends on the target and its current context"))
        #expect(instructions.contains("never automatically replay an action that may already have happened"))
        #expect(instructions.contains("observe its initial value"))
        #expect(!instructions.contains("Go to Folder opens with / in its field"))
    }

    @Test("the interpretation says Braus judges the result check: an unread one never makes carried-out steps not_completed")
    func interpretationLeavesTheResultCheckToBraus() {
        let instructions = AutomationTools.instructions
        #expect(instructions.contains("Braus judges the result check, not you"))
        #expect(instructions.contains("declare the outcome of the steps you actually"))
        #expect(instructions.contains("does not make them not_completed"))
    }

    @Test("the instructions say that document apps save an edit by themselves, and how a panel's Go to Folder takes a path")
    func autosaveAndPanelPathGuidance() {
        let instructions = AutomationTools.instructions
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
        _ = try await tools.call("act", .object(["session": .string(id), "target": .string("Salva id:'control|salva'")]))
        _ = try await tools.call("type_text", .object([
            "session": .string(id), "target": .string("id:'control|textfield'"), "text": .string("campione")
        ]))
        _ = try await tools.call("act", .object(["session": .string(id), "target": .string("Annulla")]))
        #expect(session.calls.contains("control|salva"))
        #expect(session.calls.contains("Annulla"))
        guard case .typeText(_, let field, _)? = session.inputs.first else {
            Issue.record("type_text delivered no input: \(session.inputs)")
            return
        }
        #expect(field == "control|textfield")
    }

    @Test("open_session tells every client that a kind of thing is not an app's name (rule 1)")
    func namedMeansTheAppOrItsBrand() throws {
        let definition = try #require(AutomationTools.definitions(for: .web).first { $0["name"].string == "open_session" })
        let named = definition["inputSchema"]["properties"]["named"]
        #expect(named["type"].string == "boolean")
        for text in [definition["description"].string, named["description"].string] {
            #expect(text?.contains("\"the X app\" or its brand") == true)
            #expect(text?.contains("\"with Maps\") is not a name: leave named false") == true)
        }
    }

    @Test("R09: the instructions and open_session say where the composed channels drive an app or a page, in the same words; the Seat alone keeps its text")
    func instructionsFollowTheChannels() throws {
        func openSession(_ channels: AutomationChannels) throws -> String {
            try #require(AutomationTools.definitions(for: channels).first { $0["name"].string == "open_session" }?[
                "description"].string)
        }
        let seatOnly = "All app actions happen on a background Seat."
        let browserApps = "For anything on the web, use the browser apps marks as the default"
        let native = "A native app is driven where it is, in the background behind the person's windows (the "
            + "MacDriver); when the MacDriver gives it back, it moves to a background Seat."
        let web = "A web page opens in Braus's own browser engine, with no window of the person's: open_session with "
            + "web:<host> or the page's URL."
        let seat = AutomationTools.instructions(for: [])
        #expect(seat == AutomationTools.instructions)
        #expect(seat.contains(seatOnly) && seat.contains(browserApps) && !seat.contains("web:<host>"))
        #expect(try openSession([]).hasPrefix("Adopt an app into one persistent background Seat"))
        for channels: AutomationChannels in [[.native], [.web], [.native, .web], .all] {
            let text = AutomationTools.instructions(for: channels)
            let opening = try openSession(channels)
            #expect(!text.contains(seatOnly) && !opening.contains("Adopt an app into one persistent background Seat"))
            for (sentence, channel) in [(native, AutomationChannels.native), (web, .web)] {
                #expect(text.contains(sentence) == channels.contains(channel), "\(channels)")
                #expect(opening.contains(sentence) == channels.contains(channel), "\(channels)")
            }
            #expect(text.contains(browserApps) != channels.contains(.web), "\(channels)")
            #expect(text.contains("use the browser engine (open_session with web:<host> or the page's URL) unless the "
                                  + "person names a browser app") == channels.contains(.web))
        }
        #expect(AutomationTools.instructions(for: [.native]).contains("A native app is driven on a background Seat")
                == false)
        #expect(AutomationTools.instructions(for: [.web]).contains("A native app is driven on a background Seat."))
        // An instance says what it serves.
        let tools = AutomationTools(session: SyntheticSession(), channels: [.native, .web])
        #expect(tools.instructions == AutomationTools.instructions(for: [.native, .web]))
        #expect(AutomationTools(session: SyntheticSession()).instructions == AutomationTools.instructions)
    }

    @Test("with no channel beyond the Seat the tools are the Seat's alone; each channel adds only its own")
    func channelsDecideTheTools() throws {
        func names(_ channels: AutomationChannels) -> Set<String> {
            Set(AutomationTools.definitions(for: channels).compactMap { $0["name"].string })
        }
        func openSession(_ channels: AutomationChannels) throws -> JSONValue {
            try #require(AutomationTools.definitions(for: channels).first { $0["name"].string == "open_session" })
        }
        #expect(AutomationTools.definitions == AutomationTools.definitions(for: []))
        #expect(names([]).isDisjoint(with: ["app_capabilities", "app_call"]))
        #expect(try openSession([])["inputSchema"]["properties"]["named"] == .null)
        #expect(try openSession([])["description"].string?.contains("Set named true") == false)
        #expect(names(.adapters).subtracting(names([])) == ["app_capabilities", "app_call"])
        // R02: the adapters are a route of their own, so `named` is offered with them; no web page is named.
        #expect(try openSession(.adapters)["inputSchema"]["properties"]["named"]["type"].string == "boolean")
        let adapterOnly = try openSession(.adapters)["description"].string
        #expect(adapterOnly?.contains("a better route (an app_call adapter)") == true, "\(adapterOnly ?? "")")
        // The web adds its one tool, collect_posts, which reads the page it holds.
        #expect(names(.web).subtracting(names([])) == ["collect_posts"])
        #expect(names([]).isSubset(of: names(.web)))
        #expect(try openSession(.web)["inputSchema"]["properties"]["named"]["type"].string == "boolean")
        #expect(try openSession(.web)["description"].string?.contains("app_call") == false, "no adapter to point at")
        #expect(try openSession([.web, .adapters])["description"].string?.contains("an app_call adapter") == true)
        #expect(names([.native]) == names([]))
        let tools = AutomationTools(session: SyntheticSession())
        #expect(tools.adapters == nil && tools.router == nil)
        #expect(tools.toolDefinitions == AutomationTools.definitions)
        let routed = AutomationTools(session: SyntheticSession(), channels: [.web, .adapters])
        #expect(routed.adapters != nil && routed.router != nil)
        #expect(routed.toolDefinitions == AutomationTools.definitions(for: [.web, .adapters]))
        routed.adapters = nil
        #expect(routed.toolDefinitions == AutomationTools.definitions(for: .web), "the tools follow what it can do")
    }

    @Test("an adapter tool in a composition without adapters is refused and touches no session")
    func adapterToolsNeedTheirChannel() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        await #expect(throws: AutomationFailure.self) {
            _ = try await tools.call("app_call", .object(["app": .string("Notes"), "verb": .string("notes.list")]))
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
            _ = try await tools.call("open_session", .object(arguments))
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
                try await tools.call("open_session", .object([
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
            try await tools.call("observe", .object(["session": .string(id.uuidString)]))
        }
        #expect(session.calls == ["observe"])
        let record = try #require(records.last)
        if ends {
            #expect(session.id == nil)
            #expect(!record.contains("Observe before any retry"))
            #expect(record.contains("Use status"))
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

        _ = try await tools.call("observe", .object(["session": .string(id.uuidString)]))
        #expect(records.last?.contains("\"notice\"") == false)

        session.seatNotice = "window 7 is on the person's screen"
        _ = try await tools.call("observe", .object(["session": .string(id.uuidString)]))
        #expect(records.last?.contains("window 7 is on the person's screen") == true)
        _ = try await tools.call("status", .object([:]))
        #expect(records.last?.contains("\"notice\"") == false, "only an answer with a scene carries it")
    }

    @Test("a page in the person's own Chrome says so under browser in each answer with a scene, beside the seat's")
    func aSceneCarriesTheBrowserNotice() async throws {
        let session = SyntheticSession()
        let id = try #require(session.id)
        var records: [String] = []
        let tools = AutomationTools(session: session)
        tools.record = { records.append($0) }

        _ = try await tools.call("observe", .object(["session": .string(id.uuidString)]))
        #expect(records.last?.contains("\"browser\"") == false)

        session.browserNotice = "This page is in the person's own Chrome"
        session.seatNotice    = "window 7 is on the person's screen"
        _ = try await tools.call("observe", .object(["session": .string(id.uuidString)]))
        let answer = try #require(records.last)
        #expect(answer.contains("\"browser\"") && answer.contains("This page is in the person's own Chrome"))
        #expect(answer.contains("window 7 is on the person's screen"), "the seat's notice is kept")
        _ = try await tools.call("status", .object([:]))
        #expect(records.last?.contains("\"browser\"") == false, "only an answer with a scene carries it")
    }

    @Test
    func staleSessionCannotReachTheDriver() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        do {
            _ = try await tools.call("act", .object(["session": .string("old"), "target": .string("Create")]))
            Issue.record("Stale session accepted.")
        } catch { #expect(session.calls.isEmpty) }
    }

    @Test("I04: a client that reconnects gets a session of its own; the old connection's ID reaches neither, and nothing runs")
    func reconnectRefusesTheOldID() async throws {
        let before = SyntheticSession()
        let old = try #require(before.id).uuidString
        await before.close()
        let after = SyntheticSession()
        let tools = AutomationTools(session: after)
        #expect(after.id?.uuidString != old)
        await #expect(throws: (any Error).self) {
            _ = try await tools.call("act", .object(["session": .string(old), "target": .string("Create")]))
        }
        #expect(before.calls == ["close"] && after.calls.isEmpty, "no replay on either session")
    }

    @Test
    func malformedLaterBatchStepPreventsEveryEffect() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        do {
            _ = try await tools.call("batch", .object([
                "session": .string(id.uuidString), "steps": .array([
                    .object(["operation": .string("act"), "target": .string("Create")]),
                    .object(["operation": .string("act"), "target": .string("Toggle"),
                             "verb": .string("set_toggle")])
                ])
            ]))
            Issue.record("Malformed batch accepted.")
        } catch { #expect(session.calls.isEmpty) }
    }

    @Test
    func batchStopsOnUnverifiedWithoutReplayingOrContinuing() async throws {
        let session = SyntheticSession()
        session.results = [.foundActed, .actedUnverified, .foundActed]
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.call("batch", .object([
            "session": .string(id.uuidString), "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls == ["First", "Second"])
        #expect(result.payload["status"].string == "stopped")
        #expect(result.payload["steps"].array?.count == 2)
        #expect(result.payload["verifiedSteps"] == .number(1))
    }

    @Test
    func thrownBatchFailureKeepsEarlierResults() async throws {
        let session = SyntheticSession()
        session.throwOnTarget = "Second"
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.call("batch", .object([
            "session": .string(id.uuidString), "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls == ["First", "Second"])
        #expect(result.payload["verifiedSteps"] == .number(1))
        #expect(result.payload["steps"].array?.last?["status"].string == "error")
    }

    @Test("A terminal batch failure keeps prior effects and never advises observing its ended ID")
    func aTerminalBatchFailureNeedsDiscovery() async throws {
        let session = SyntheticSession()
        session.throwOnTarget = "Second"
        session.endsWhenActFails = true
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.call("batch", .object([
            "session": .string(id.uuidString), "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls == ["First", "Second"])
        #expect(session.id == nil)
        #expect(result.payload["verifiedSteps"] == .number(1))
        let guidance = try #require(result.payload["steps"].array?.last?["guidance"].string)
        #expect(guidance.contains("Earlier effects remain"))
        #expect(guidance.contains("Use status"))
        #expect(!guidance.contains("Observe before"))
    }

    @Test
    func separateToolCallsBorrowOneSessionUntilExplicitClose() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let arguments = JSONValue.object(["session": .string(id.uuidString)])
        _ = try await tools.call("observe", arguments)
        _ = try await tools.call("observe", arguments)
        #expect(session.id == id)
        #expect(session.calls == ["observe", "observe"])
        _ = try await tools.call("close_session", arguments)
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
        let result = try await tools.call("close_session", .object(["session": .string(id.uuidString)]))

        #expect(session.id == nil)
        #expect(result.payload["status"].string == "closed")
        #expect(result.payload["warning"].string == warning)
    }

    @Test
    func windowsUsesTheSessionsDiscoveryWithoutOpeningASeat() async throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let session = SyntheticSession()
        session.discoveryRows = [WindowRow(layer: 0, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                           title: "Owned offscreen fixture", number: 987_654)]
        let result = try await AutomationTools(session: session).call("windows", .object([
            "app": .string("com.apple.finder")
        ]))
        #expect(session.discoveryReads == [finder.processIdentifier])
        #expect(session.calls.isEmpty)
        #expect(result.payload["applications"].array?.first?["windows"] == .array([
            .object(["id": .number(987_654), "title": .string("Owned offscreen fixture")])
        ]))
    }

    @Test
    func inputToolsAreListedWithTheirSchemas() throws {
        let tools = Dictionary(uniqueKeysWithValues: AutomationTools.definitions.map { ($0["name"].string ?? "", $0) })
        let required: [String: [String]] = [
            "type_text": ["session", "target", "text"], "insert_text": ["session", "text"],
            "press_key": ["session", "key"],
            "scroll": ["session", "direction"], "drag": ["session", "from"],
            "context_menu": ["session", "target", "item"], "menu": ["session", "path"], "press": ["session", "button"]
        ]
        for (name, fields) in required {
            let tool = try #require(tools[name], "missing tool \(name)")
            #expect(tool["inputSchema"]["required"].array?.compactMap(\.string) == fields)
            #expect(tool["annotations"]["readOnlyHint"] == .bool(false))
        }
        let key = tools["press_key"]?["inputSchema"]["properties"]
        let names = key?["key"]["enum"].array?.compactMap(\.string) ?? []
        #expect(["return", "tab", "escape", "space", "delete", "left", "up", "a", "z", "0", "9"]
            .allSatisfy(names.contains))
        #expect(key?["modifiers"]["items"]["enum"].array?.compactMap(\.string) == ["cmd", "shift", "opt", "ctrl"])
        #expect(key?["count"]["maximum"] == .number(Double(InputRequest.maximumKeyPresses)))
        let verbs = tools["act"]?["inputSchema"]["properties"]["verb"]["enum"].array?.compactMap(\.string) ?? []
        #expect(verbs.contains("triple_click"))
        let steps = tools["batch"]?["inputSchema"]["properties"]["steps"]["items"]["oneOf"].array ?? []
        #expect(steps.compactMap { $0["properties"]["operation"]["const"].string }
            == ["act", "select", "type_text", "insert_text", "press_key", "scroll", "drag", "context_menu"])
        #expect(!AutomationTools.instructions.contains("Typing, scrolling, keyboard shortcuts"))
        #expect(AutomationTools.instructions.contains("may need explicit focus before accepting keys"))
        #expect(AutomationTools.instructions.contains("use the browser apps marks as the default"))
        #expect(AutomationTools.instructions.contains("its other visible windows move to the seat's display too"))
        // Text goes in one type_text: both the instructions and the key's own description say so.
        #expect(AutomationTools.instructions.contains("never one press_key per character"))
        #expect(tools["press_key"]?["description"].string?.contains("never for text: use type_text") == true)
    }

    @Test
    func insertionPreservesTheExistingFocusWithoutATarget() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id).uuidString
        let result = try await tools.call("insert_text", .object([
            "session": .string(id), "text": .string("Braus-à-中-🙂")
        ]))
        #expect(result.payload["status"].string == "found_acted")
        #expect(session.inputs.count == 1)
        #expect(session.inputs == [.insertText("Braus-à-中-🙂")])
        #expect(session.sections == [nil])
        _ = try await tools.call("insert_text", .object([
            "session": .string(id), "text": .string("Braus"),
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
            try await tools.call(name, .object(arguments.merging(["session": .string(id)], uniquingKeysWith: { $1 })))
        }
        let typed = try await call("type_text", ["target": .string("Project Name"), "text": .string("My Project")])
        #expect(typed.payload["status"].string == "found_acted")
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
            ("press_key", ["key": .string("f20")]),
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
                _ = try await tools.call(name, .object(arguments.merging(["session": id], uniquingKeysWith: { $1 })))
                Issue.record("\(name) accepted \(arguments)")
            } catch {}
        }
        #expect(session.calls.isEmpty)
    }

    @Test
    func batchStopsBeforeReturnWhenInsertionIsUnverified() async throws {
        let session = SyntheticSession()
        session.results = [.actedUnverified, .foundActed]
        let result = try await AutomationTools(session: session).call("batch", .object([
            "session": .string(try #require(session.id).uuidString), "steps": .array([
                .object(["operation": .string("insert_text"), "text": .string("Braus")]),
                .object(["operation": .string("press_key"), "key": .string("return")])
            ])
        ]))
        #expect(session.inputs == [.insertText("Braus")])
        #expect(result.payload["status"].string == "stopped")
        #expect(result.payload["attemptedSteps"] == .number(1))
        #expect(result.payload["verifiedSteps"] == .number(0))
    }

    @Test
    func batchCarriesInputStepsAndStopsOnAnUnverifiedKey() async throws {
        let session = SyntheticSession()
        session.results = [.foundActed, .actedUnverified, .foundActed]
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.call("batch", .object([
            "session": .string(id.uuidString), "steps": .array([
                .object(["operation": .string("type_text"), "target": .string("Name"), "text": .string("Demo")]),
                .object(["operation": .string("press_key"), "key": .string("return")]),
                .object(["operation": .string("scroll"), "direction": .string("down")])
            ])
        ]))
        #expect(session.inputs == [.typeText("Demo", into: "Name", replacing: true),
                                   .pressKey(KeyChord(.return), times: 1)])
        #expect(result.payload["status"].string == "stopped")
        #expect(result.payload["verifiedSteps"] == .number(1))
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
        #expect(opening(true).contains("web:<host>") && opening(true).contains("A file:// address is refused"))
        #expect(!AutomationTools.instructions.contains("web:<host>"))
        let web = AutomationTools.instructions(offeringAdapters: false, offeringWeb: true)
        #expect(web.contains("call open_session with web:<host> or an http(s) address"))
        #expect(!web.contains("use the browser apps marks as the default"))
        let tools = AutomationTools(session: SyntheticSession(), offersWeb: true)
        #expect(tools.toolDefinitions == AutomationTools.definitions(offeringAdapters: false, offeringWeb: true))
        #expect(tools.instructions == AutomationTools.instructions(offeringAdapters: false, offeringWeb: true))
    }

    @Test
    func appsIsListedReadOnlyWithAnOptionalQuery() throws {
        let apps = try #require(AutomationTools.definitions.first { $0["name"].string == "apps" })
        #expect(apps["annotations"]["readOnlyHint"] == .bool(true))
        #expect(apps["inputSchema"]["required"] == .array([]))
        #expect(apps["inputSchema"]["properties"].object?.keys.sorted() == ["query"])
        #expect(apps["description"].string?.contains("then pass its bundleID to open_session") == true)
        #expect(apps["description"].string?.contains("defaultBrowser on the browser that opens web links") == true)
    }

    @Test
    func appsMarksTheDefaultBrowserAndOnlyIt() async throws {
        let session = CatalogueSession(candidates: [
            ApplicationCandidate(name: "Browser", bundleID: "com.example.Browser", version: "1.0", isRunning: true,
                                 isDefaultBrowser: true),
            ApplicationCandidate(name: "Other Browser", bundleID: "com.example.Other", version: nil, isRunning: true)
        ])
        let result = try await AutomationTools(session: session).call("apps", .null)
        #expect(result.payload == .object(["applications": .array([
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
        let result = try await tools.call("apps", .object(["query": .string("pro tools")]))
        #expect(session.queries == ["pro tools"])
        #expect(result.payload == .object(["applications": .array([
            .object(["name": .string("Pro Tools"), "bundleID": .string("com.avid.ProTools"),
                     "version": .string("26.4.1.179"), "running": .bool(false)]),
            .object(["name": .string("Pro Tools"), "bundleID": .string("com.example.ProTools"),
                     "running": .bool(true), "location": .string("~/Applications")])
        ])]))
        #expect(records.first?.hasPrefix("→ apps ") == true)
        #expect(records.last?.hasPrefix("← apps ") == true)

        _ = try await tools.call("apps", .null)
        #expect(session.queries == ["pro tools", nil])
    }

    @Test
    func appsListsSixtyAndCountsTheRest() async throws {
        let many = (1...61).map { ApplicationCandidate(name: "App \($0)", bundleID: "com.example.\($0)", version: nil,
                                                       isRunning: false) }
        let result = try await AutomationTools(session: CatalogueSession(candidates: many)).call("apps", .null)
        #expect(result.payload["applications"].array?.count == 60)
        #expect(result.payload["more"] == .string("1 more not listed; pass a query to find them."))
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
        let observed = try await tools.call("observe", .object(["session": id])).payload
        #expect(observed["scene"].string == session.scene.text())
        #expect(observed["changes"] == .null)

        session.scene = Self.scene(Self.rows.map { $0 == "Track 7 volume" ? "Track 7 muted" : $0 })
        let acted = try await tools.call("act", .object(["session": id, "target": .string("Track 7")]))
        #expect(acted["structuredContent"] == .null)
        let observation = acted.payload["observation"]
        let changes = try #require(observation["changes"].string)
        #expect(observation["scene"] == .null)
        #expect(observation["since"] == observed["revision"])
        #expect(changes.hasPrefix("## Tracks @0,0 100x100\n"))
        #expect(changes.contains("\n~ [control] Track 7 muted @10,24  (was label \"Track 7 volume\")"))
        #expect(!changes.contains("Track 8"))
        // The result names the session once; its observation repeats neither it nor the time.
        #expect(acted.payload["session"] == id)
        #expect(observation["session"] == .null)
        #expect(observation["observedAt"] == .null)
        #expect(observed["session"] == id)
        #expect(observed["observedAt"] != .null)

        #expect(observation["revision"] == .number(2))
        let again = try await tools.call("act", .object(["session": id, "target": .string("Track 7")]))
        #expect(again.payload["observation"]["changes"] == .string("Unchanged since revision 2."))
    }

    @Test("observe answers the changes since the model's scene of the window, or the whole scene when asked")
    func observeSendsChangesUnlessAskedForTheWholeScene() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        let first = try await tools.call("observe", .object(["session": id])).payload
        #expect(first["scene"].string == session.scene.text())

        let polled = try await tools.call("observe", .object(["session": id])).payload
        #expect(polled["changes"] == .string("Unchanged since revision 1."))
        #expect(polled["since"] == .number(1))
        #expect(polled["scene"] == .null)

        session.scene.elements[0].state = .on
        let changed = try await tools.call("observe", .object(["session": id])).payload
        let stated = "~ [control] Track 1 volume [on] @10,0  (was no state)"
        #expect(changed["changes"].string?.contains(stated) == true)
        #expect(changed["since"] == .number(2))

        let whole = try await tools.call("observe", .object(["session": id, "full": .bool(true)])).payload
        #expect(whole["scene"].string == session.scene.text())
        #expect(whole["changes"] == .null)
        let again = try await tools.call("observe", .object(["session": id, "full": .bool(false)])).payload
        #expect(again["changes"] == .string("Unchanged since revision 4."))

        let calls = session.calls
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("observe", .object(["session": id, "full": .string("yes")]))
        }
        #expect(session.calls == calls)
        let definition = try #require(AutomationTools.definitions.first { $0["name"].string == "observe" })
        // A container is accepted where a section is, and the parameter says so.
        let act = try #require(AutomationTools.definitions.first { $0["name"].string == "act" })
        #expect(act["inputSchema"]["properties"]["section"]["description"].string?.contains("{container}") == true)
        let opening = try #require(AutomationTools.definitions.first { $0["name"].string == "open_session" })
        #expect(opening["description"].string?.contains("\"icons: id@x,y id×n\"") == true)
        #expect(definition["description"].string?.contains("\"~ changed (was ...)\"") == true)
        #expect(definition["inputSchema"]["properties"]["full"]["type"] == .string("boolean"))
        #expect(definition["inputSchema"]["required"] == .array([.string("session")]))
    }

    @Test("open_session sends its scene whole even when the model read that window before")
    func openingSendsTheWholeScene() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.call("observe", .object(["session": .string(try #require(session.id).uuidString)]))
        let opened = try await tools.call("open_session", .object(["app": .string("Synthetic Mixer")])).payload
        #expect(opened["scene"].string == session.scene.text())
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
        _ = try await tools.call("observe", .object(["session": id]))

        let dialog = Self.scene((1...12).map { "Option \($0)" }, title: "Rename Track")
        session.scene = dialog
        session.observedWindowNumber = mainNumber.map { $0 + 1 }
        let opened = try await tools.call("act", .object(["session": id, "target": .string("Rename")])).payload
        #expect(opened["observation"]["scene"].string == dialog.text())

        // The dialog loses its title between two readings, as one did on Resolve; it is the same window.
        session.scene.windowTitle = ""
        let typed = try await tools.call("act", .object(["session": id, "target": .string("Name")])).payload
        #expect(typed["observation"]["since"] == .number(2))
        #expect(typed["observation"]["changes"].string?.contains("window: Synthetic Mixer (test.synthetic)") == true)

        session.scene = Self.scene(Self.rows.map { $0 == "Track 7 volume" ? "Track 7 renamed" : $0 })
        session.observedWindowNumber = mainNumber
        let closed = try await tools.call("act", .object(["session": id, "target": .string("OK")])).payload
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
            _ = try await tools.call("observe", .object(["session": id]))
        }
        session.scene = Self.scene(Self.rows, title: "Window 8")
        #expect(try await tools.call("observe", .object(["session": id])).payload["changes"]
            == .string("Unchanged since revision 9."))
        session.scene = Self.scene(Self.rows, title: "Window 0")
        #expect(try await tools.call("observe", .object(["session": id])).payload["scene"].string
            == session.scene.text())
    }

    @Test("a call whose answer never reached the model leaves the baseline the model read")
    func aFailedCallKeepsTheBaseline() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.call("observe", .object(["session": id]))

        session.scene.elements[0].state = .on
        tools.record = { if $0.hasPrefix("← observe") { throw AutomationFailure("transcript unavailable") } }
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("observe", .object(["session": id]))
        }
        tools.record = nil
        let next = try await tools.call("observe", .object(["session": id])).payload
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
        _ = try await tools.call("observe", .object(["session": id]))
        let after = isAnotherWindow ? Self.scene(Self.rows, title: "Another window")
            : Self.scene(Self.rows.map { $0 + " (soloed)" })
        session.scene = after
        let acted = try await tools.call("act", .object(["session": id, "target": .string("Track 1")]))
        #expect(acted.payload["observation"]["scene"].string == after.text())
        #expect(acted.payload["observation"]["changes"] == .null)
    }

    @Test
    func anActionAfterTheSceneIsForgottenSendsItWhole() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.call("observe", .object(["session": id]))

        tools.forgetScene()
        let acted = try await tools.call("act", .object(["session": id, "target": .string("Track 1")]))
        #expect(acted.payload["observation"]["scene"].string == session.scene.text())
        #expect(acted.payload["observation"]["changes"] == .null)
    }

    @Test
    func closingTheSessionForgetsTheSceneTheModelRead() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.call("observe", .object(["session": .string(id.uuidString)]))
        _ = try await tools.call("close_session", .object(["session": .string(id.uuidString)]))
        // The synthetic session takes its old ID back: only a forgotten baseline makes this scene whole.
        session.id = id
        let acted = try await tools.call("act", .object([
            "session": .string(id.uuidString), "target": .string("Track 1")
        ]))
        #expect(acted.payload["observation"]["scene"].string == session.scene.text())
        #expect(acted.payload["observation"]["changes"] == .null)
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
    var id: UUID? = UUID()
    var closeWarning: String?
    var seatNotice: String?
    var browserNotice: String?
    var observedWindowNumber: Int?
    var calls: [String] = []
    var openedWindowTitles: [String?] = []
    var results: [ActOutcomeKind] = []
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
                              viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [])

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
        return ActOutcome(results.isEmpty ? .foundActed : results.removeFirst(), "synthetic result", scene: scene)
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        calls.append("select")
        return ActOutcome(.foundActed, "synthetic selection", scene: scene)
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        calls.append("deliver")
        inputs.append(input)
        sections.append(section)
        return ActOutcome(results.isEmpty ? .foundActed : results.removeFirst(), "synthetic input", scene: scene)
    }

    func close() async { calls.append("close"); id = nil }
}
