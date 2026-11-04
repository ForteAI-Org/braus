import LocalMCP
import AutomationRuntime
import EngineCore
import Memory
import Turn

nonisolated enum TaskStateFixtures {
    static let rows = [
        TodoRow(id: .init(rawValue: "r1"), title: "Prepare"),
        TodoRow(id: .init(rawValue: "r2"), title: "Submit"),
        TodoRow(id: .init(rawValue: "r3"), title: "Verify")
    ]

    static func todo(_ number: Int, change: TodoRevision.Change, rows: [TodoRow] = rows) -> TaskStateInput {
        .init(fact: .todo(TodoEvent(.init(taskID: "task", number: number, change: change,
            rows: rows, recordedAtMS: 0), origin: .model)), origin: .runner,
            sequence: nil, key: "todo.task.\(number)")
    }

    static func call(_ number: Int, subject: String = "Submit", outcome: Outcome) -> TaskStateInput {
        .init(fact: .callFinished(tool: "act", subject: subject, outcome: outcome), origin: .dispatcher,
              sequence: number, key: "c\(number).finished")
    }

    static let confirmed = Outcome(gesture: .sent, effect: .confirmed, recovery: .continue)
    static let absent = Outcome(gesture: .sent, effect: .absent, recovery: .retry)
    static let uncertain = Outcome(gesture: .uncertain, effect: .unknown(.notReadable), recovery: .doNotRepeat)

    private static let firstTask: [TaskStateInput] = {
        var closed = rows
        closed[0].status = .done
        closed[1].status = .inProgress
        return [
            .init(fact: .request("Prepare, submit and verify the item."), origin: .runner,
                  sequence: nil, key: "t1.request"),
            todo(1, change: .drafted),
            .init(fact: .callFailed(tool: "act", reason: "Target unavailable"), origin: .dispatcher,
                  sequence: 1, key: "c1.failed"),
            call(2, outcome: absent),
            todo(2, change: .revised(reason: "Verify before continuing"), rows: closed),
            call(3, outcome: uncertain),
            .init(fact: .loaded(.schema(capability: "editing")), origin: .dispatcher,
                  sequence: 4, key: "c4.schema"),
            .init(fact: .loaded(.guide(id: "editing", section: "Submission")), origin: .dispatcher,
                  sequence: 4, key: "c4.guide"),
            .init(fact: .personIntervention(digest: "Selected Submit.\nUnobserved: completion."),
                  origin: .runner, sequence: nil, key: "t2.person")
        ]
    }()

    static let tasks: [[TaskStateInput]] = [firstTask, [
        .init(fact: .request("Prepare the draft and save it."), origin: .runner,
              sequence: nil, key: "t1.request"),
        todo(1, change: .drafted),
        call(1, subject: "Prepare", outcome: confirmed),
        call(2, subject: "Save", outcome: .init(gesture: .notSent, effect: .notApplicable, recovery: .askPerson)),
        .init(fact: .personIntervention(digest: "Selected Save. Details: §1"), origin: .runner,
              sequence: nil, key: "t2.person"),
        call(3, subject: "Save", outcome: confirmed)
    ], [
        .init(fact: .request("Check the submission and stop if it cannot be confirmed."), origin: .runner,
              sequence: nil, key: "t1.request"),
        todo(1, change: .drafted),
        call(1, outcome: uncertain),
        todo(2, change: .stopped, rows: rows.map {
            var row = $0
            row.status = .abandoned
            return row
        }),
        .init(fact: .loaded(.guide(id: "editing", section: "Verification")), origin: .dispatcher,
              sequence: 2, key: "c2.guide")
    ]]

    static func state(_ inputs: [TaskStateInput] = tasks[0]) -> TaskState {
        var state = TaskState()
        for input in inputs { state.apply(input) }
        return state
    }
}
