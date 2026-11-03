//
//  BrainIndex.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import PerceptionCore
import Synchronization

/// BrainIndex is the prebuilt lookup over one brain snapshot, so matching costs a dictionary probe
/// instead of a scan per element. Per-element scans were the measured cause of a scene description
/// slowing from four to ten seconds as a brain learned. The index is valid only for the exact
/// snapshot it was built from.
public struct BrainIndex: Sendable {

    /// Normalized label or alias to object indices, each object once per normal.
    let byNormalizedLabel: [String: [Int]]
    /// Model-named anchors by kind; they hold positional pull.
    let modelNamedByKind: [ElementKind: [Int]]
    let indexByKey: [String: Int]

    struct NormalizedForms: Sendable {
        let label: String
        let all: Set<String>
    }

    /// Work events are supplied by offline checks, never retained by the snapshot.
    enum Work: Equatable {
        case normalization
        case ordinalCandidate
        case spatialProbe
    }

    let normalizedByAnchor: [NormalizedForms]
    private final class SpatialCache: Sendable {
        let value = Mutex<BrainSpatialIndex?>(nil)
    }

    private let spatialCache = SpatialCache()
    var spatialIsBuilt: Bool { spatialCache.value.withLock { $0 != nil } }

    /// Shares one complete spatial index; construction runs outside the storage lock.
    func spatial(in brain: UIBrain) -> BrainSpatialIndex {
        spatial(in: brain, checking: {})
    }

    func spatial(in brain: UIBrain, checking check: () throws -> Void) rethrows -> BrainSpatialIndex {
        try check()
        if let cached = spatialCache.value.withLock({ $0 }) { return cached }
        let built = try BrainSpatialIndex(brain, indexByKey: indexByKey, checking: check)
        return try spatialCache.value.withLock { cached in
            try check()
            if let cached { return cached }
            cached = built
            return built
        }
    }

    public init(_ brain: UIBrain) {
        self.init(brain, checking: {}, recording: nil)
    }

    init(_ brain: UIBrain, recording: ((Work) -> Void)?) {
        self.init(brain, checking: {}, recording: recording)
    }

    /// Builds an index cooperatively; a thrown check leaves no index to publish.
    public init(_ brain: UIBrain, checking check: () throws -> Void) rethrows {
        try self.init(brain, checking: check, recording: nil)
    }

    init(_ brain: UIBrain, checking check: () throws -> Void, recording: ((Work) -> Void)?) rethrows {
        try check()
        var byLabel: [String: [Int]] = [:]
        var modelNamed: [ElementKind: [Int]] = [:]
        var byKey: [String: Int] = Dictionary(minimumCapacity: brain.objects.count)
        var forms: [NormalizedForms] = []
        for (index, object) in brain.objects.enumerated() {
            try check()
            byKey[object.anchorKey] = index
            var normals: Set<String> = []
            recording?(.normalization)
            let label = LabelText.normalize(object.label)
            if !label.isEmpty { normals.insert(label) }
            for alias in object.aliases {
                try check()
                recording?(.normalization)
                let normal = LabelText.normalize(alias)
                if !normal.isEmpty { normals.insert(normal) }
            }
            forms.append(NormalizedForms(label: label, all: normals))
            for normal in normals { byLabel[normal, default: []].append(index) }
            if object.labelSource == .llm { modelNamed[object.kind, default: []].append(index) }
        }
        byNormalizedLabel  = byLabel
        modelNamedByKind   = modelNamed
        indexByKey         = byKey
        normalizedByAnchor = forms
    }

    /// Conservative estimate including normalized strings, dictionary buckets and spatial entries.
    /// Every membership reserves space for a cell and both fallback lists, even when shared.
    func estimatedBytes(in brain: UIBrain, checking check: () throws -> Void) rethrows -> Int {
        try check()
        func text(_ value: String) -> Int { 64 + value.utf8.count * 2 }
        var bytes = 512 + indexByKey.count * 128
        for (key, values) in byNormalizedLabel { try check(); bytes += text(key) + 128 + values.count * 16 }
        for values in modelNamedByKind.values { try check(); bytes += 128 + values.count * 16 }
        for forms in normalizedByAnchor {
            try check()
            bytes += 128 + text(forms.label)
            for value in forms.all { try check(); bytes += 64 + text(value) }
        }
        bytes += brain.groups.count * 256
        bytes += try brain.groups.reduce(0) { try check(); return $0 + $1.memberAnchors.count * 512 }
        return bytes
    }

    /// The anchor with this key in the indexed snapshot.
    func object(_ key: String, in brain: UIBrain) -> ObjectAnchor? {
        indexByKey[key].map { brain.objects[$0] }
    }
}

/// BrainProjection owns a naming snapshot and its matching index together. Readers can retain it
/// across cache eviction; it never stores detections or a previous scene's enriched elements.
/// The estimate includes collection slack, string storage and the index, rather than serialized size.
public final class BrainProjection: Sendable {
    public let brain: UIBrain
    public let estimatedBytes: Int
    package let requiresSceneSlice: Bool
    private let index: BrainIndex

    public convenience init(_ brain: UIBrain) {
        self.init(brain, checking: {})
    }

    /// Stops index construction and byte accounting before an incomplete snapshot can escape.
    public init(_ brain: UIBrain, checking check: () throws -> Void) rethrows {
        try check()
        self.brain = brain
        let index = try BrainIndex(brain, checking: check)
        self.index = index
        // SQL's ordinal lookup distinguishes raw empty labels from normalized empty labels.
        requiresSceneSlice = try brain.objects.enumerated().contains {
            try check()
            return !$0.element.label.isEmpty && index.normalizedByAnchor[$0.offset].label.isEmpty
        }
        func text(_ value: String) -> Int { 64 + value.utf8.count * 2 }
        var bytes = 1024 + (try index.estimatedBytes(in: brain, checking: check))
        bytes += brain.objects.count * MemoryLayout<ObjectAnchor>.stride * 2
        for anchor in brain.objects {
            try check()
            bytes += text(anchor.anchorKey) + text(anchor.label) + text(anchor.window ?? "")
            for alias in anchor.aliases { try check(); bytes += 32 + text(alias) }
            for state in anchor.statesSeen.keys { try check(); bytes += 128 + text(state) }
        }
        bytes += brain.groups.count * MemoryLayout<SiblingGroup>.stride * 2
        for group in brain.groups {
            try check()
            bytes += text(group.name ?? "")
            for member in group.memberAnchors { try check(); bytes += 32 + text(member) }
        }
        bytes += brain.transitions.count * MemoryLayout<LearnedTransition>.stride * 2
        for transition in brain.transitions { try check(); bytes += text(transition.anchorKey) + text(transition.effect) }
        for window in brain.windowEpochs.keys { try check(); bytes += 128 + text(window) }
        self.estimatedBytes = bytes
    }

    /// Names the current elements with this snapshot's index, preserving the naming-only contract.
    public func enrich(_ elements: [SceneElement]) -> [SceneElement] {
        enrich(elements, checking: {})
    }

    /// Reuses this snapshot's index while checking the current read between elements.
    public func enrich(_ elements: [SceneElement], checking check: () throws -> Void) rethrows -> [SceneElement] {
        try brain.enrich(elements, affordances: false, index: index, checking: check)
    }
}
