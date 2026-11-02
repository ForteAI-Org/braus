import Foundation
import InteractionObservation

/// HumanActionProvenance separates input time from post-delivery AX observation time. An unchanged
/// input revision only fences the probe; target attribution also needs matching observations on both sides.
nonisolated struct HumanActionProvenance: Codable, Sendable {
    let version: Int
    let interval: InteractionSemanticSnapshot.Interval
    let sourceSequence: UInt64
    let targetInferred: Bool
    var stateAtAction: Bool
    var semantics: InteractionSemanticSnapshot?
    var beforeSemantics: InteractionSemanticSnapshot?

    init(interval: InteractionSemanticSnapshot.Interval, sourceSequence: UInt64,
         targetInferred: Bool, stateAtAction: Bool = false, semantics: InteractionSemanticSnapshot? = nil,
         beforeSemantics: InteractionSemanticSnapshot? = nil) {
        version = 1
        self.interval = interval
        self.sourceSequence = sourceSequence
        self.targetInferred = targetInferred
        self.stateAtAction = stateAtAction
        self.semantics = semantics
        self.beforeSemantics = beforeSemantics
    }

    var postActionState: InteractionSemanticSnapshot? {
        guard version == 1, stateAtAction, interval.isValid, let semantics, semantics.version == 1,
              semantics.interval.isValid, semantics.interval.start >= interval.end,
              semantics.interval.start - interval.end <= 0.75,
              semantics.interval.end - semantics.interval.start <= 0.1 else { return nil }
        return semantics
    }

    private var before: InteractionSemanticSnapshot? {
        guard let beforeSemantics, beforeSemantics.version == 1, beforeSemantics.interval.isValid,
              beforeSemantics.interval.end <= interval.start,
              interval.start - beforeSemantics.interval.end <= 15,
              beforeSemantics.processID == semantics?.processID else { return nil }
        return beforeSemantics
    }

    /// Focus observed only after Return may be its result. Do not substitute it for the recipient.
    var attestedState: InteractionSemanticSnapshot? {
        guard let after = postActionState, let before,
              let first = before.focusedElement, let last = after.focusedElement,
              let key = before.identityKey(first), key == after.identityKey(last) else { return nil }
        return after
    }

    /// Objects selected in the document at the action. Both sides must agree when both are attested.
    /// For an action on another surface (a palette or popover), the action cannot change the document's
    /// selection itself, and the pre-action observation is the previous action's attested state with no
    /// recorded input in between; it alone attests the selection when the post-action probe was fenced out
    /// by later input. A post-action observation that disagrees always wins.
    func affectedObjects(in document: Int, processID: Int32, actionWindow: Int? = nil) -> [String] {
        guard let before, before.processID == processID, let lhs = before.selection(in: document),
              let collection = before.identityKey(lhs.collection) else { return [] }
        let old = Set(lhs.objects.compactMap { before.identityKey($0) })
        guard !old.isEmpty, old.count == lhs.objects.count else { return [] }
        if let after = postActionState, after.processID == processID {
            guard let rhs = after.selection(in: document), collection == after.identityKey(rhs.collection),
                  Set(rhs.objects.compactMap { after.identityKey($0) }) == old, rhs.objects.count == old.count
            else { return [] }
            return rhs.objects.compactMap(\.label).sorted()
        }
        guard let actionWindow, actionWindow != document else { return [] }
        return lhs.objects.compactMap(\.label).sorted()
    }
}
