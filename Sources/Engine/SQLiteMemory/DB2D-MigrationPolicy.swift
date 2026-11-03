import Foundation

/// MigrationPolicy controls conversion of an existing archive; readers always refuse conversion.
public enum MigrationPolicy: Sendable, Equatable {
    case automatic
    case onlyWithFlag(Bool)
    case never

    var permitsMigration: Bool {
        switch self {
        case .automatic: true
        case .onlyWithFlag(let enabled): enabled
        case .never: false
        }
    }
}

extension SQLiteMemoryStore {
    /// MigrationProgress is the latest coordinator progress, readable while opening is in flight.
    public struct MigrationProgress: Sendable, Equatable {
        public let phase: String
        public let rowsDone: Int
        public let rowsTotal: Int
    }
}
