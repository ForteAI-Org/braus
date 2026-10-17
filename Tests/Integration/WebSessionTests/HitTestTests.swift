import CoreGraphics
import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving

/// W10 and W09: a click, and any pointer gesture over a target (a right click, the click that focuses a field, a
/// scroll, a drag), reaches only the element the page would hit at its point. Something on top of it (an overlay, a
/// banner) or a scroll container clipping it, and a node gone since the scene, refuse the gesture with nothing sent.
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

    // MARK: Every pointer gesture over a target (W10)

    private static let gestures = ["right click", "type", "scroll", "drag"]

    /// The gesture named over the field Nome, through the engine.
    private static func over(_ gesture: String, _ stack: SyntheticForm.Stack) async -> ActOutcome {
        func input(_ input: InputRequest.Input) async -> ActOutcome {
            await stack.engine.deliver(InputRequest(processID: stack.processID, bundleID: "web:fixture.test",
                                                    appName: "fixture.test", input: input))
        }
        switch gesture {
            case "right click":
                return await stack.engine.act(ActionRequest(processID: stack.processID, bundleID: "web:fixture.test",
                                                            appName: "fixture.test", target: "Nome", verb: .rightClick))
            case "type":   return await input(.typeText("Grace", into: "Nome", replacing: true))
            case "scroll": return await input(.scroll(lines: -2, over: "Nome"))
            default:       return await input(.drag(from: "Nome", to: .offset(dx: 0, dy: 300)))
        }
    }

    @Test("a right click, the focusing click of a text, a scroll, a drag over a covered field: refused, nothing sent",
          arguments: gestures)
    func coveredPointerGestures(gesture: String) async throws {
        let stack = await SyntheticForm.stack()
        stack.page.change([.cover(CGRect(x: 0, y: 180, width: 1280, height: 80), name: "Cookie")])
        let outcome = await Self.over(gesture, stack)
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("Cookie"), Comment(rawValue: outcome.message))
        #expect(stack.page.count(of: "Input.dispatchMouseEvent") == 0, "no mouse event reached the page")
        #expect(stack.page.count(of: "Input.dispatchKeyEvent") == 0 && stack.page.count(of: "Input.insertText") == 0)
    }

    @Test("the same gestures with the banner elsewhere go out (positive control)", arguments: gestures)
    func uncoveredPointerGestures(gesture: String) async throws {
        let stack = await SyntheticForm.stack()
        stack.page.change([.cover(CGRect(x: 0, y: 600, width: 1280, height: 80), name: "Cookie")])
        let outcome = await Self.over(gesture, stack)
        #expect(outcome.kind != .refused, Comment(rawValue: outcome.message))
        #expect(stack.page.count(of: "Input.dispatchMouseEvent") > 0, "the gesture went out")
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
