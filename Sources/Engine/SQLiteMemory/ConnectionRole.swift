import Dispatch

/// ConnectionRole identifies a connection's fixed execution priority and page cache.
package enum ConnectionRole: Sendable, Equatable {
    case writer
    case reader(index: Int)
    case bulk

    var qos: DispatchQoS { self == .bulk ? .utility : .userInitiated }

    func cacheSizeKiB(in configuration: SQLiteMemoryStore.Configuration) -> Int32 {
        switch self {
        case .writer: configuration.writerCacheKiB
        case .reader: configuration.readerCacheKiB
        case .bulk: configuration.bulkCacheKiB
        }
    }
}
