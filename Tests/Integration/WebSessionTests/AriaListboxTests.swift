import AutomationRuntime
import CoreGraphics
import Engine
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving
@testable import WebSession

/// W05: `select` on an ARIA combo box whose list opens in the page itself, so no window is drawn for it. The option
/// is clicked by its node, through the engine, and the choice is judged by what the control reads back after the page
/// settled. A missing option, an ambiguous or disabled one, or no list at all is answered before a second click.
/// Over `ScriptedAriaPage`, with the production web roles and engine: what the DOM does is the Chrome tier's.
@Suite("Choosing in an ARIA list in the page (W05)")
@MainActor
struct AriaListboxTests {

    private static func choose(_ item: String, on page: ScriptedAriaPage, control: String = "Colore") async throws -> ActOutcome {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("braus-w05-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = await CDPConnection(transport: page)
        let tabs = WebTabs()
        let processID = tabs.register(WebPage(connection: connection, targetID: "target-1", sessionID: "session-1"))
        let runtime = WebEngineRuntime(knowledgeDirectory: directory, tabs: tabs)
        defer { Task { await runtime.service.close() } }
        let recorder = runtime.recorder(ActionContext(source: .app, streamID: "w05", traceID: "w05", sessionID: "s1"))
        let outcome = try await WebAutomationSession.select(control: control, item: item, processID: processID,
                                                            runtime: runtime) { target in
            await runtime.engine(recorder: recorder, allowsDestructive: false)
                .act(ActionRequest(processID: processID, bundleID: "web:fixture.test", appName: "fixture.test",
                                   target: target, verb: .click))
        }
        #expect((try? runtime.windows.windows(ownedBy: processID).count) == 1, "no window was drawn for the list")
        return outcome
    }

    @Test("the option named is clicked by its node, and the control reading it back after settling passes the check")
    func chosen() async throws {
        let page = ScriptedAriaPage()
        let outcome = try await Self.choose("Blu", on: page)
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.check?.condition == .valueReadBack && outcome.check?.verdict == .passed)
        #expect(outcome.check?.expected == "Blu" && outcome.check?.observed == "Blu")
        #expect(page.pressCount == 2, "the control, then the option")
        let option = try #require(ScriptedAriaPage.options.first { $0.name == "Blu" })
        #expect(page.presses.last.map(option.box.contains) == true, "the second press landed on Blu")
        #expect(page.shownValue == "Blu")
    }

    @Test("twins share their scene id, so the scene names neither's node: the option is placed by its box, and the press lands on the second Blu")
    func twinPlacedByItsBox() async throws {
        let page = ScriptedAriaPage(options: ScriptedAriaPage.twins, found: 23)
        let outcome = try await Self.choose("Blu #2", on: page)
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        let second = try #require(ScriptedAriaPage.twins.last)
        #expect(page.presses.last.map(second.box.contains) == true, "the second press landed on the second Blu")
        #expect(page.pressCount == 2)
    }

    @Test("a control that reads another value after settling fails the check, and nothing is chosen again")
    func notKept() async throws {
        let page = ScriptedAriaPage(readBacks: ["Blu", "Rosso"])
        let outcome = try await Self.choose("Blu", on: page)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.check?.verdict == .failed && outcome.check?.observed == "Rosso")
        #expect(page.pressCount == 2, "no replay")
    }

    @Test("a control that cannot be read back leaves the check unknown, and nothing is chosen again")
    func unread() async throws {
        let page = ScriptedAriaPage(readBacks: [.null])
        let outcome = try await Self.choose("Blu", on: page)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.check?.verdict == .unknown && outcome.check?.limits.contains(.readbackUnavailable) == true)
        #expect(page.pressCount == 2)
    }

    @Test("an option the open list does not have is an honest miss, after the opening click only")
    func missing() async throws {
        let page = ScriptedAriaPage(optionsAnswer: ["kind": "missing", "reason": "the open list has no option of that name"])
        let outcome = try await Self.choose("Viola", on: page)
        #expect(outcome.kind == .honestMiss, Comment(rawValue: outcome.message))
        #expect(page.pressCount == 1, "nothing was clicked in the list")
    }

    @Test("several options of that name, or a disabled one, are refused with nothing more sent",
          arguments: ["several options have that name; name one as the scene shows it, with its ordinal",
                      "that option is disabled", "more than one list is open in the page"])
    func refused(reason: String) async throws {
        let page = ScriptedAriaPage(optionsAnswer: ["kind": "refused", "reason": .string(reason)])
        let outcome = try await Self.choose("Blu", on: page)
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("no option was clicked") && outcome.message.contains(reason))
        #expect(!outcome.message.contains("nothing was sent"), "the opening click went out")
        #expect(page.pressCount == 1)
    }

    @Test("another control's list left open: a control that opens nothing chooses nothing in it, and nothing is clicked there")
    func anotherControlsList() async throws {
        let page = ScriptedAriaPage(startsOpen: true)
        let outcome = try await Self.choose("Blu", on: page, control: "Aiuto")
        #expect(outcome.check?.condition != .valueReadBack, Comment(rawValue: outcome.message))
        #expect(page.pressCount == 1, "only the click on Aiuto")
        #expect(page.presses.allSatisfy(ScriptedAriaPage.help.contains), "no press on Colore's list")
        #expect(page.shownValue == "Rosso", "Colore keeps its value")
    }

    @Test("a control that opens no list answers its click, as before: no second click")
    func noList() async throws {
        let page = ScriptedAriaPage(opensOnPress: false)
        let outcome = try await Self.choose("Blu", on: page)
        #expect(outcome.check?.condition != .valueReadBack, Comment(rawValue: outcome.message))
        #expect(page.pressCount == 1 && page.optionQueryCount == 1)
    }
}
