import CoreGraphics
import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving

/// W10 and W09: a click reaches only the element the page would hit at its point. Something on top of it (an overlay,
/// a banner) or a scroll container clipping it, and a node gone since the scene, refuse the click with nothing sent.
/// Over `SyntheticPage`, whose `cover` change lays an element over a box, with the production web roles. The page's own
/// hit testing (shadow roots, pointer events, clipping) is the Chrome tier's.
@Suite("A click reaches what the page would hit (W10, W09)")
struct HitTestTests {

    private static func click(_ target: String, _ stack: SyntheticForm.Stack) async -> ActOutcome {
        await stack.engine.act(ActionRequest(processID: stack.processID, bundleID: "web:fixture.test", appName: "fixture.test",
                                             target: target, verb: .click))
    }

    @Test("a banner over the field: the click is refused, the banner named, nothing was sent, no press reached the page")
    func covered() async throws {
        let stack = await SyntheticForm.stack()
        stack.page.change([.cover(CGRect(x: 0, y: 180, width: 1280, height: 80), name: "Cookie")])
        let outcome = await Self.click("Nome", stack)
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("nothing was sent") && outcome.message.contains("Cookie"),
                Comment(rawValue: outcome.message))
        #expect(stack.page.pressCount == 0)
    }

    @Test("a banner elsewhere: the click on the field goes out (positive control)")
    func coverElsewhere() async throws {
        let stack = await SyntheticForm.stack()
        stack.page.change([.cover(CGRect(x: 0, y: 600, width: 1280, height: 80), name: "Cookie")])
        let outcome = await Self.click("Nome", stack)
        #expect(outcome.kind != .refused, Comment(rawValue: outcome.message))
        #expect(stack.page.pressCount == 1)
    }

    @Test("the field replaced by a new node in its place after the engine read the scene: refused, nothing was sent")
    func replacedBeforeDispatch() async throws {
        let stack = await SyntheticForm.stack()
        stack.page.schedule([.replace(12, by: 52)], afterScene: 1)
        let outcome = await Self.click("Nome", stack)
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("nothing was sent"), Comment(rawValue: outcome.message))
        #expect(stack.page.pressCount == 0)
    }

    @Test("a label the last scene does not give at the point names no node: the click is refused before any event")
    func unbound() async throws {
        let stack = await SyntheticForm.stack()
        let window = try await WebScenes(tabs: stack.tabs).currentScene(of: stack.processID)
        let field = try #require(window.scene.elements.first { $0.label == "Nome" })
        let refused = await #expect(throws: GestureNotSent.self) {
            try await WebActuator(tabs: stack.tabs).perform(.click(at: window.globalPoint(of: field)), expecting: "Accesso",
                                                            in: stack.processID)
        }
        #expect(refused?.reason == "target_unbound")
        #expect(stack.page.pressCount == 0)
    }
}
