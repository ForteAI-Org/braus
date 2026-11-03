import AutomationRuntime
import PerceptionCore
import Testing

struct WorkerValueGuardTests {
    @Test(arguments: ["Key", "Token", "PIN", ""])
    func weakLabelsRemainReadable(label: String) {
        #expect(!ProductionPerception.workerValueGuard.refusesLabel(label))
    }

    @Test func decisiveLabelsRefuseReading() {
        #expect(ProductionPerception.workerValueGuard.refusesLabel("Password"))
    }
}
