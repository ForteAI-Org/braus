import LocalMCP
import EngineCore
import AutomationRuntime
import Memory
import Testing
import Turn

struct TodoEventsTests {
    @Test func reasonRevisionAndOriginSurviveTurnEvent() {
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Prepare", status: .inProgress,
                          expected: .element(app: nil, label: "Ready", expect: .present))
        let revision = TodoRevision(taskID: "task", number: 3, change: .revised(reason: "Add verification"),
                                    rows: [row], recordedAtMS: 7)
        let gesture = TodoGesture(eventID: "call", row: row.id, outcome: "passed")
        let change = TodoEvent(revision, origin: .model, gestures: [gesture])
        let event = TurnRunEvent.todo(change)
        guard case .todo(let read) = event else { Issue.record("Lost todo event"); return }
        #expect(read.reason == "Add verification")
        #expect(read.revision == 3)
        #expect(read.origin == .model)
        #expect(read.rows == [row])
        #expect(read.gestures == [gesture])
    }

    @Test func stopBelongsToBrausAndCarriesAbandonedRows() {
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Prepare", status: .abandoned)
        let change = TodoEvent(.init(taskID: "task", number: 4, change: .stopped, rows: [row], recordedAtMS: 9), origin: .braus)
        #expect(change.origin == .braus)
        #expect(change.kind == .stopped)
        #expect(change.changed == [row.id])
        #expect(change.reason == nil)
    }
}
