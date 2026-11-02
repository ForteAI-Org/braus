import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
@testable import AutomationMCP

@MainActor
final class ReplaySession: AutomationSessionOperating {
    var id: UUID?
    var observedWindowNumber: Int?

    func open(application: String, window: String?) async throws -> SceneSnapshot { throw unexpected() }
    func observe() async throws -> SceneSnapshot { throw unexpected() }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw unexpected()
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw unexpected() }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw unexpected() }
    func menu(path: String) async throws -> ActOutcome { throw unexpected() }
    func close() async { id = nil }
    private func unexpected() -> ReplayFailure { ReplayFailure("Replay must only call the formatter") }
}

@MainActor
func regenerateTrace(_ input: ReplayInput) async throws -> [JSONValue] {
    let session = ReplaySession()
    session.id = input.session
    let secrets = ProducerSecrets()
    let sceneText = SceneTextPolicy()
    let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
    defer { withExtendedLifetime((secrets, sceneText)) {} }
    var trace: [JSONValue] = []
    for item in input.prefix + [input.outcome] {
        session.observedWindowNumber = item.windowNumber
        trace.append(await formatter.outcome(try item.converted()))
    }
    return trace
}

@MainActor
func regenerate(_ input: ReplayInput) async throws -> JSONValue {
    guard let last = try await regenerateTrace(input).last else { throw ReplayFailure("Empty trace") }
    return last
}

func replayBytes(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
