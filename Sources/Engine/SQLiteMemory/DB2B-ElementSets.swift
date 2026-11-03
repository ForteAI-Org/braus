import Memory
import PerceptionCore

/// DB2BElementSets derives a shared set from the sample's exact structural content.
enum DB2BElementSets {
    static func record(_ transaction: SQLiteTransaction, _ sample: CaptureSample) throws -> Int64 {
        let members = try sample.elements.map { element in
            try DB2BElementSetRows.element(
                in: transaction,
                fields: [
                    element.role, element.kind.rawValue, element.label, element.labelOrigin?.rawValue,
                    element.containerPath, element.state?.rawValue,
                ]
            )
        }
        return try DB2BElementSetRows.set(in: transaction, members: members)
    }
}
