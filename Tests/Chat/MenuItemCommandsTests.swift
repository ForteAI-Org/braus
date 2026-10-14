//
//  MenuItemCommandsTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import ApplicationServices
@testable import AutomationRuntime
import EngineCore
import PerceptionCore
import Testing

/// A format toggle falls back to its click only when its menu command reached no press: the menu
/// tool's own answers, read through the convention `MenuItemCommands.dispatched` relies on.
@MainActor
@Suite("A menu command for a format toggle")
struct MenuItemCommandsTests {

    struct Failure: Error {}

    private func prepared(_ resolution: MenuBarCommand.Resolution<Int>, error: AXError = .success) async -> ActOutcome {
        await MenuBarCommand.runPrepared(preparesEnabledItems: false, read: { resolution }, press: { _ in error },
                                         refresh: nil).outcome
    }

    @Test("a missing, disabled or refused item and a listing were not dispatched")
    func notDispatched() async {
        let missing  = await prepared(.outcome(ActOutcome(.honestMiss, "No item 'Bold' in Format > Font.")))
        let refused  = await prepared(.outcome(ActOutcome(.refused, "Format > Font > Bold reads as destructive.")))
        let disabled = await prepared(.disabled(path: "Format > Font > Bold"))
        let listing  = await prepared(.list(path: "Format > Font", items: ["Bold"]))
        for outcome in [missing, refused, disabled, listing] {
            #expect(MenuItemCommands.dispatched(outcome) == nil, Comment(rawValue: outcome.message))
        }
    }

    @Test("a press that went out, or may have, answers instead of the click")
    func dispatched() async {
        let failed = await prepared(.press(1, path: "Format > Font > Bold"), error: .failure)
        #expect(MenuItemCommands.dispatched(failed) == failed, "a failed press may have acted")
        let inFront = ActOutcome(.actedUnverified, "pressed Format > Font > Bold. The front did not come back.")
        #expect(MenuItemCommands.dispatched(inFront) == inFront)
        let menus = MenuItemCommands { _, _, _ in throw Failure() }
        let thrown = await menus.performMenuItem("Format > Font > Bold", in: 1, observe: { throw Failure() })
        #expect(thrown?.kind == .actedUnverified)
        #expect(thrown?.check?.performed == .uncertain)
    }

    @Test("the session's command is given the path, the application and the engine's observation")
    func forwards() async throws {
        let menus = MenuItemCommands { path, processID, observe in
            ActOutcome(.actedUnverified, "pressed \(path) in \(processID)", scene: try await observe(),
                       check: MenuBarCommand.windowCheck(.unknown))
        }
        let scene = SceneSnapshot(bundleID: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled",
                                  viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [])
        let outcome = try #require(await menus.performMenuItem("Format > Font > Bold", in: 42, observe: { scene }))
        #expect(outcome.message == "pressed Format > Font > Bold in 42")
        #expect(outcome.scene?.windowTitle == "Untitled")
    }

    @Test("a press made with the application brought forward for a moment says so, once")
    func broughtForward() async throws {
        let path = "Format > Font > Bold"
        let pressed: MenuItemCommands.Command = { path, _, _ in
            ActOutcome(.actedUnverified, "pressed \(path).", check: MenuBarCommand.windowCheck(.unknown))
        }
        let inFront = try #require(await MenuItemCommands(pressed, inFront: "TextEdit")
            .performMenuItem(path, in: 1, observe: { throw Failure() }))
        #expect(inFront.message == "pressed Format > Font > Bold. TextEdit was brought forward for a moment to press "
            + "the menu item.")
        let background = await MenuItemCommands(pressed).performMenuItem(path, in: 1, observe: { throw Failure() })
        #expect(background?.message == "pressed Format > Font > Bold.", "a background press keeps its own answer")
        // A handback that was not verified already says the application was brought forward.
        let troubled = ActOutcome(.actedUnverified, "pressed \(path). It was brought forward for a moment, but the "
            + "return to the person's own window was not verified.",
            check: MenuBarCommand.windowCheck(.unknown, limits: [.deliveryUncertain], performed: .uncertain))
        let unverified = await MenuItemCommands({ _, _, _ in troubled }, inFront: "TextEdit")
            .performMenuItem(path, in: 1, observe: { throw Failure() })
        #expect(unverified == troubled)
        let missing = await MenuItemCommands({ _, _, _ in ActOutcome(.honestMiss, "No item 'Bold'.") },
                                             inFront: "TextEdit")
            .performMenuItem(path, in: 1, observe: { throw Failure() })
        #expect(missing == nil, "nothing was pressed, so the click goes out")
    }
}
