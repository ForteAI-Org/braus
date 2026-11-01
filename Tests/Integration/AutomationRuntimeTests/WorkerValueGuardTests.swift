import AutomationRuntime
import Testing

struct WorkerValueGuardTests {
    @Test(arguments: ["Key", "Token", "PIN", "Password", ""])
    func noLabelIsReserved(label: String) {
        #expect(!ProductionPerception.workerValueGuard(label))
    }
}
