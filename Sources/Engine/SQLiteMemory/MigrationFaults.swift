/// MigrationFaults stops an operation at a persistence boundary without production side effects.
/// A thrown hook leaves files at that boundary; the next recovery uses the durable record.
package struct MigrationFaults: Sendable {
    package enum Boundary: Sendable, Equatable {
        case phase(SQLiteMigration22.Phase)
        case beforeRecord, afterRecord
        case afterRename(RenameStep)
        case recovery(step: Int)
    }

    package enum RenameStep: Sendable, Equatable { case sidecars, source, built }

    package let hit: @Sendable (Boundary) throws -> Void
    package static let none = MigrationFaults { _ in }

    package init(_ hit: @escaping @Sendable (Boundary) throws -> Void) {
        self.hit = hit
    }
}
