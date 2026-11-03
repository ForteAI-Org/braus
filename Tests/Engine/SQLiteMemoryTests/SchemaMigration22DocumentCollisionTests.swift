import Foundation
import Memory
import Testing

@testable import SQLiteMemory

/// Preserves the row-count gate when two supported historical formats produce the same text.
@Suite("SchemaMigration22 document preservation gate")
struct SchemaMigration22DocumentCollisionTests {
    @Test
    func equalTextInDifferentHistoricalFormatsMustKeepBothDocumentRows() throws {
        let source = try SQLiteConnection(path: ":memory:")
        let target = try SQLiteConnection(path: ":memory:")
        defer { source.close(); target.close() }
        try source.execute(SQLiteMemorySchema.historical19Text())
        try source.execute("PRAGMA user_version=19")
        let text = "Save method. In Synthetic. Steps: Save."
        for format in [RecallDocument.Format.labelled, .contextual] {
            try source.run("""
                INSERT INTO memory_recall_documents(document_digest,document_format,text,recorded_at_ms) VALUES (?,?,?,0)
                """, [.text(SQLiteRecallRepository.digest(format: format, text: text)),.text(format.rawValue),.text(text)])
        }
        #expect(try source.query("PRAGMA integrity_check") { try $0.text(0) } == ["ok"])
        #expect(try source.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
        #expect(try SQLiteMemorySchema.objects(in: source) == SQLiteMemorySchema.objects(of: SQLiteMemorySchema.historical19Text()))
        try source.execute("BEGIN")
        try target.execute(SQLiteMigration22File.text().components(separatedBy: "-- section: indexes")[0])
        try target.execute("BEGIN")
        let plan = try SQLiteMigration22Plan(source: source, target: target)
        let content = try SQLiteMigration22Content(source: source, target: target, plan: plan)
        let copied: Result<Int, any Error> = Result {
            try SQLiteMigration22RowCopy.copy("memory_recall_documents", from: source, into: target, keys: plan.keys,
                                              fields: plan.fields(for: "memory_recall_documents", overriding: content.fields(for: "memory_recall_documents")))
        }
        let sourceCount: [Int64?] = try source.query("SELECT count(*) FROM memory_recall_documents") { $0.integer(0) }
        let destinationCount: [Int64?] = try target.query("SELECT count(*) FROM memory_recall_documents") { $0.integer(0) }
        #expect(sourceCount == [2])
        #expect(destinationCount == sourceCount)
        _ = try copied.get()
        let formats: [String?] = try target.query("SELECT document_format FROM memory_recall_documents ORDER BY document_format") { try $0.text(0) }
        #expect(formats == ["recall-document-1", "recall-document-1c"])
    }
}
