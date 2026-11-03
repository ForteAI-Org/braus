import Foundation

/// TodoRevision appends one change to a task's plan, using its own revision sequence.
public struct TodoRevision: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case drafted
        case revised(reason: String?)
        case rowStarted(TodoRowID)
        case rowFinished(TodoRowID, verdict: RowVerdict?)
        case stopped
    }
    public enum RowVerdict: String, Sendable, Equatable { case passed, failed, unknown }
    public let taskID: String
    public let number: Int
    public let change: Change
    public let rows: [TodoRow]
    /// Calls buffered since the prior write. Schema 22 stores no revision link for calls; revision
    /// readback returns this empty. Read `TodoStoring.attributedCalls(ofTask:item:)` for stored attribution.
    public let attributedCalls: [CallAttribution]
    /// Explicit predicate changes whose operands can encode to the same withheld archive form.
    public let revisedExpectations: Set<TodoRowID>
    public let recordedAtMS: Int64

    public init(taskID: String, number: Int, change: Change, rows: [TodoRow],
                attributedCalls: [CallAttribution] = [], recordedAtMS: Int64, revisedExpectations: Set<TodoRowID> = []) {
        self.revisedExpectations = revisedExpectations
        self.taskID = taskID
        self.number = number
        self.change = change
        self.rows = rows
        self.attributedCalls = attributedCalls
        self.recordedAtMS = recordedAtMS
    }

    public func forTask(_ taskID: String) -> TodoRevision {
        TodoRevision(taskID: taskID, number: number, change: change, rows: rows,
                     attributedCalls: attributedCalls, recordedAtMS: recordedAtMS, revisedExpectations: revisedExpectations)
    }
}

/// CallAttribution links a recorded gesture to the subprocedure it served.
public struct CallAttribution: Sendable, Equatable {
    public let eventID: String
    public let row: TodoRowID
    public init(eventID: String, row: TodoRowID) { self.eventID = eventID; self.row = row }
}
