import EngineCore
import Foundation
import PerceptionCore
import Memory

/// A frozen historical projection accepts no new mutations. The result carries that decision separately from a receipt.
public enum BrainProjectionWrite<Value: Sendable>: Sendable {
    case applied(Value)
    case frozen
}

extension SQLiteBrainRepository {
    /// Reports the frozen destination without presenting an import as committed.
    public func importProjectionResult(_ brain: UIBrain, into bundleID: String, now: Date) async throws -> BrainProjectionWrite<Bool> {
        if try await projectionIsFrozen() { return .frozen }
        return .applied(try await importProjection(brain, into: bundleID, now: now))
    }
}

extension BrainApplicationResult {
    /// Zero is reserved for the no-op answer; no application row is inserted on a frozen destination.
    public var projectionWrite: BrainProjectionWrite<BrainApplicationResult> {
        applicationID == 0 ? .frozen : .applied(self)
    }
}


enum DB2CFrozenProjection {
    static let tables = ["brain_anchors", "brain_anchor_aliases", "brain_anchor_states", "brain_groups", "brain_group_members",
        "brain_transitions", "brain_transition_menu_items", "brain_applications", "brain_relation_applications",
        "brain_anchor_label_keys", "memory_variant_prefixes"]
}

extension SQLiteBrainRepository {
    public func ingestResult(_ detections: [BrainDetection], into bundleID: String, now: Date,
                             window: String?) async throws -> BrainProjectionWrite<BrainUpdater.IngestStats> {
        if try await projectionIsFrozen() { return .frozen }
        return .applied(try await ingest(detections, into: bundleID, now: now, window: window))
    }

    public func observeResult(_ scene: SceneSnapshot, now: Date) async throws -> BrainProjectionWrite<BrainUpdater.IngestStats> {
        if try await projectionIsFrozen() { return .frozen }
        return .applied(try await observe(scene, now: now))
    }

    public func recordResult(_ record: ActionRecord, now: Date) async throws -> BrainProjectionWrite<BrainRecordOutcome> {
        if try await projectionIsFrozen() { return .frozen }
        return .applied(try await self.record(record, now: now))
    }

    public func setNameResult(_ name: String, anchorKey: String, in bundleID: String, now: Date) async throws -> BrainProjectionWrite<Bool> {
        if try await projectionIsFrozen() { return .frozen }
        return .applied(try await setName(name, anchorKey: anchorKey, in: bundleID, now: now))
    }

    public func decayResult(in bundleID: String, now: Date, maxObjects: Int = 3000,
                            retention: BrainRetention = .standard) async throws -> BrainProjectionWrite<DecayReport> {
        if try await projectionIsFrozen() { return .frozen }
        return .applied(try await decay(in: bundleID, now: now, maxObjects: maxObjects, retention: retention))
    }

    public func mergeResult(_ brain: UIBrain, into bundleID: String, origin: String,
                            now: Date) async throws -> BrainProjectionWrite<BrainMerge> {
        if try await projectionIsFrozen() { return .frozen }
        return .applied(try await merge(brain, into: bundleID, origin: origin, now: now))
    }
}
