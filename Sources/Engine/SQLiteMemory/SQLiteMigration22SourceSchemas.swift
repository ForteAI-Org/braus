/// Exact object digests from the supplied schema fixtures. No source DDL is inferred or rebuilt.
enum SQLiteMigration22SourceSchemas {
    static func digest(version: Int64) -> String? {
        switch version {
        case 20: "d911c182cc4e5aa4bb2d2b31efbcb6a9cc8e5b52fd71af4eddc84e9ac0177289"
        case 21: "031790e0ce7e886248d09819968cffad09e3df4af1acfd99060b9519593be81f"
        default: nil
        }
    }
}
