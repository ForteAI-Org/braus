import AutomationRuntime
import EngineCore
import Foundation
import PerceptionCore

/// DemoSession supplies an identity and refuses application operations in capability tests.
@MainActor
final class DemoSession: AutomationSessionOperating {
    var id: UUID? = UUID()

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        throw SessionError.unexpectedCall
    }

    func observe() async throws -> SceneSnapshot {
        throw SessionError.unexpectedCall
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw SessionError.unexpectedCall
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        throw SessionError.unexpectedCall
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw SessionError.unexpectedCall
    }

    func close() async { id = nil }

    private enum SessionError: Error { case unexpectedCall }
}
