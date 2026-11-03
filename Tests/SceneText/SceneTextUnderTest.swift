import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Switches
@testable import AutomationMCP

struct RenderedScene: Sendable {
    let text      : String
    let brainParts: [String]
    let kind      : String?
}

/// SceneTextUnderTest reads the whole answer and its memory spans through the model policy.
enum SceneTextUnderTest {
    @MainActor
    static func render(_ scene: SceneSnapshot) async throws -> RenderedScene {
        await SwitchBoard.$testing.withValue(SwitchBoard(values: ["scene_text": "v2", "scene_text_policy": "chained"])) {
            let answer = await SceneTextPolicy().answer(scene, changesOnly: false,
                session: SceneTextSession(), shown: ValueMinimization())
            let bytes = Array(answer.text.utf8)
            return RenderedScene(text: answer.text,
                brainParts: answer.parts.filter { $0.source == .memory }.map {
                    String(decoding: bytes[$0.utf8], as: UTF8.self)
                }, kind: nil)
        }
    }
}

@MainActor
private final class SceneTextSession: AutomationSessionOperating {
    let id: UUID? = nil
    func open(application: String, window: String?) async throws -> SceneSnapshot { throw unexpected() }
    func observe() async throws -> SceneSnapshot { throw unexpected() }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw unexpected()
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw unexpected() }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw unexpected() }
    func menu(path: String) async throws -> ActOutcome { throw unexpected() }
    func close() async {}
    private func unexpected() -> SceneTextFailure { SceneTextFailure("Rendering must not operate a session") }
}
