import Memory
import SQLiteMemory

/// RecallFilters rejects unavailable methods before scoring limits, using already cached metadata.
nonisolated struct RecallFilters: Sendable {
    let bundleIDs: Set<String>?
    let availableChannels: Set<String>
    let doNotUse: Set<ProcedureFamilyID>

    func admits(_ slot: SQLiteRecallRepository.IndexEntry, _ admissibility: RecallAdmissibility?) -> Bool {
        guard let admissibility, !admissibility.fromFailedAttempt,
              !doNotUse.contains(admissibility.family),
              admissibility.channels.isSubset(of: availableChannels) else { return false }
        guard let bundle = slot.bundleID, let bundleIDs else { return true }
        return bundleIDs.contains(bundle)
    }
}
