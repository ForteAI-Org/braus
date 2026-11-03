/// TodoStoring appends snapshots only against the revision the caller read.
public protocol TodoStoring: Sendable {
    func current(of taskID: String) async throws -> Todo?
    func append(_ revision: TodoRevision, expecting: Int) async throws -> Todo
    func revisions(of taskID: String) async throws -> [TodoRevision]
    func attributedCalls(ofTask taskID: String, item: TodoRowID?) async throws -> [CallAttribution]
}

/// TodoStoreError preserves unavailable archives, stale writers and invalid declarations as typed failures.
public enum TodoStoreError: Error, Sendable, Equatable {
    case unavailable(schemaVersion: Int)
    case staleRevision(expected: Int, current: Int)
    case invalid(String)
    case unknownTask(String)
    case unknownCall(String)
}
