import Foundation

/// TodoRowID names a row assigned by Braus and stable throughout a task.
public struct TodoRowID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// TodoRow is one subprocedure, with its expected result and current state.
public struct TodoRow: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case pending, inProgress = "in_progress", done, abandoned
    }
    public let id: TodoRowID
    public var title: String
    public var app: String?
    public var status: Status
    public var part: String?
    public var expected: TaskResultCheck.Expectation?

    public init(id: TodoRowID, title: String, app: String? = nil, status: Status = .pending,
                part: String? = nil, expected: TaskResultCheck.Expectation? = nil) {
        self.id = id
        self.title = title
        self.app = app
        self.status = status
        self.part = part
        self.expected = expected
    }
}

/// Todo is an ordered snapshot; abandoned rows retain history without consuming the active row limit.
public struct Todo: Sendable, Equatable {
    public let taskID: String
    public let revision: Int
    public let rows: [TodoRow]
    public static let rowLimit = 10
    public static let titleLimit = 120
    public static let expectedLimit = 160

    public init(taskID: String, revision: Int, rows: [TodoRow]) {
        self.taskID = taskID
        self.revision = revision
        self.rows = rows
    }
}
