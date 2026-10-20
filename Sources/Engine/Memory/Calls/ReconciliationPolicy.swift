import EngineCore

/// ReconciliationPolicy interprets retained read evidence, independently of SQLite, apps and transports.
/// Only the supported effect contracts below can resolve an uncertainty. Unknown effects stay blocked.
public enum ReconciliationPolicy {
    public static let version = "reconciliation-1"

    /// A resource's existence proves supported creation; a state-changing operation needs that resource's state.
    public static func supportsAdapter(adapter: String, verb: String, resource: String,
                                       results: [StructuredField], finding: CallReconciliation.Finding?) -> Bool {
        let kept = results.filter { $0.withheld == nil }
        let identifiers = kept.filter { $0.namesAnItem && $0.text == resource }
        guard !identifiers.isEmpty else { return false }
        if adapter == "reminders", verb == "complete_reminder" {
            guard finding == .happened || finding == .notHappened else { return false }
            return identifiers.contains { identifier in
                guard let slash = identifier.path.lastIndex(of: "/") else { return false }
                let parent = String(identifier.path.prefix(upTo: slash))
                return kept.contains {
                    $0.path == parent + "/completed" && $0.kind == .boolean
                        && $0.text == (finding == .happened ? "true" : "false")
                }
            }
        }
        let creations: Set<String> = ["notes:create_note", "calendar:create_event", "reminders:create_reminder", "contacts:create_contact"]
        return creations.contains(adapter + ":" + verb) && finding == .happened
    }

}
