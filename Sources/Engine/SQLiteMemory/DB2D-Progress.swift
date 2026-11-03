import Synchronization

/// DB2DProgress shares opening progress with status readers without scheduling actor messages.
final class DB2DProgress: Sendable {
    let value = Mutex<SQLiteMemoryStore.MigrationProgress?>(nil)
}
