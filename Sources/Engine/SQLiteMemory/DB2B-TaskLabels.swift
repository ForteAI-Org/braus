import Memory

/// DB2BTaskLabels returns store-assigned label identities without storing producer IDs.
enum DB2BTaskLabels {
    static func insert(
        _ transaction: SQLiteTransaction,
        _ offered: TaskLabelRecord
    ) throws -> (receipt: MemoryReceipt, label: TaskLabelRecord) {
        guard try SQLiteTaskRows.occurrence(transaction, id: offered.taskOccurrenceID) != nil else {
            throw EventFactError.missingOccurrence(id: offered.taskOccurrenceID)
        }
        try transaction.execute(
            """
            INSERT INTO memory_task_labels(task_occurrence_id,label,assigned_by,confidence,status,assigned_at_ms)
            VALUES (?,?,?,?,?,?)
            """,
            [
                try SQLiteRowIdentity(transaction).key(.attempt, offered.taskOccurrenceID), .text(offered.label),
                .text(offered.assignedBy), offered.confidence.map(SQLiteValue.real) ?? .null,
                .text(offered.status.rawValue), .integer(offered.assignedAtMS),
            ]
        )
        return (.committed, try copy(offered, id: String(SQLiteIdentityRows.lastInsertedRow(transaction))))
    }

    private static func copy(_ label: TaskLabelRecord, id: String) throws -> TaskLabelRecord {
        try TaskLabelRecord(
            labelID: id,
            taskOccurrenceID: label.taskOccurrenceID,
            label: label.label,
            assignedBy: label.assignedBy,
            confidence: label.confidence,
            status: label.status,
            assignedAtMS: label.assignedAtMS
        )
    }
}
