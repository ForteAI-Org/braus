import Foundation

/// DB2BEventSQL supplies the two event layouts while ordinary stores still use schema 19.
enum DB2BEventSQL {
    static func order(_ handle: some SQLiteQuerying, alias: String = "") throws -> String {
        let prefix = alias.isEmpty ? "" : alias + "."
        return prefix + (try SQLiteRowIdentity(handle).usesIntegerKeys ? "event_id" : "local_order")
    }

    static func uuid(_ handle: some SQLiteQuerying, alias: String = "") throws -> String {
        let prefix = alias.isEmpty ? "" : alias + "."
        return prefix + (try SQLiteRowIdentity(handle).usesIntegerKeys ? "event_uuid" : "event_id")
    }
}
