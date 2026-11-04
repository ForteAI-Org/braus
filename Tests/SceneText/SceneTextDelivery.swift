import CryptoKit
import Foundation
import PerceptionCore

/// SceneTextDelivery validates an explicit SC0 handoff before exposing recorded goldens.
/// Review declarations bind the delivered bytes; their authenticity still requires independent review.
enum SceneTextDelivery {
    private struct FileReference: Decodable {
        let path: String
        let sha256: String
    }

    private struct Capture: Decodable {
        let id: String
        let family: String
        let role: String
        let quality: String
        let nativeAX: NativeAX?
        let corpusID: String
        let callID: String
        let capturedAt: String
        let sourceRevision: String
        let binarySHA256: String
        let rendererSHA256: String
        let rawSceneSHA256: String
        let rawTextSHA256: String
        let scene: FileReference
        let recordedText: FileReference
        let expectedModelText: FileReference
        let coverage: Coverage
    }

    private struct NativeAX: Decodable {
        let bundleID: String
        let fixtureSourceSHA256: String
        let fixtureBinarySHA256: String
        let receipt: FileReference
    }

    private struct NativeObservation: Decodable {
        let format: String
        let source: String
        let callID: String
        let bundleID: String
        let sceneSHA256: String
        let fixtureSourceSHA256: String
        let fixtureBinarySHA256: String
        let rawNativeReceiptSHA256: String
        let outOfViewFieldCount: Int
        let literalLFObserved: Bool
        let headingPrefixObserved: Bool
    }

    private struct Coverage: Decodable, Equatable {
        let outOfView: Bool
        let duplicateOutOfViewLabels: Bool
        let multilineLabel: Bool
        let headingPrefixLabel: Bool
        let brainWindow: Bool

        init(_ scene: SceneSnapshot) {
            let labels = scene.outOfViewFields.map(\.label)
            outOfView = !labels.isEmpty
            let named = labels.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            duplicateOutOfViewLabels = Set(named).count < named.count
            multilineLabel = scene.elements.contains { $0.label.contains("\n") || $0.label.contains("\r") }
            headingPrefixLabel = scene.elements.contains { $0.label.hasPrefix("## ") }
            brainWindow = scene.knowledge?.status == .applied
                && scene.knowledge?.window.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
        }
    }

    private struct Review: Decodable {
        let status: String
        let reviewer: String
        let filesSHA256: [String: String]
        let captureMetadataSHA256: String?
    }

    private struct PrivacyProof: Decodable {
        let status: String
        let privateControlSHA256: String
        let policySHA256: String
        let remainingMatches: Int
    }

    private struct Manifest: Decodable {
        let format: String
        let corpusID: String
        let recordedTextContract: String
        let expectedModelTextContract: String
        let instances: FileReference
        let declaration: FileReference
        let captures: [Capture]
        let privacyProof: PrivacyProof
        let privacyReview: Review
        let expectedModelTextReview: Review
    }

    private struct Instance: Decodable {
        let id: String
        let value: String
        let caseIDs: [String]
        let observations: [PositiveObservation]
    }

    private struct PositiveObservation: Decodable {
        let caseID: String
        let sourceRecordID: String
        let scene: FileReference
        let receipt: FileReference
        let fieldPath: String
        let matchedRendering: String
    }

    private struct ObservationReceipt: Decodable {
        let format: String
        let callID: String
        let capturedAt: String
        let sceneSHA256: String
        let rawSceneSHA256: String
        let binarySHA256: String
        let sourceRevision: String
        let sourceReceiptSHA256: String
        let neutralizationProofSHA256: String

        enum CodingKeys: String, CodingKey {
            case format
            case callID = "call_id", capturedAt = "captured_at", sceneSHA256 = "scene_sha256"
            case rawSceneSHA256 = "raw_scene_sha256", binarySHA256 = "binary_sha256"
            case sourceRevision = "source_revision", sourceReceiptSHA256 = "source_receipt_sha256"
            case neutralizationProofSHA256 = "neutralization_proof_sha256"
        }
    }

    private struct DeclaredInstance: Decodable {
        let id: String
        let value: String
        let caseIDs: [String]
        let declaredRenderings: [String]?

        enum CodingKeys: String, CodingKey {
            case id, value
            case caseIDs = "case_ids", declaredRenderings = "declared_renderings"
        }
    }

    private struct Declaration: Decodable {
        let format: String
        let id: String
        let registeredAt: String
        let primaryFamilies: [String]
        let supplementaryFamilies: [String]
        let nativeFixtureBundle: String
        let inputs: [DeclaredInstance]
        let fileRoots: [DeclaredInstance]

        enum CodingKeys: String, CodingKey {
            case format, id, inputs
            case registeredAt = "registered_at", primaryFamilies = "primary_families"
            case supplementaryFamilies = "supplementary_families", nativeFixtureBundle = "native_fixture_bundle"
            case fileRoots = "file_roots"
        }
    }

    private struct Instances: Decodable {
        let format: String
        let corpusID: String
        let sourceSHA256: String
        let selectionMethod: String
        let originalScriptRecovered: Bool
        let inputs: [Instance]
        let fileRoots: [Instance]
    }

    private static let families: Set<String> = [
        "calculator", "textedit", "save", "open", "reminders", "preview", "finder", "calendar"
    ]

    /// Rejects missing data, mismatched provenance or review state rather than returning an empty corpus.
    static func load(from root: URL) throws -> [GoldenScene] {
        let decoder = JSONDecoder()
        let manifestData = try read("manifest.json", under: root)
        let manifest = try decoder.decode(Manifest.self, from: manifestData)
        try require(manifest.format == "braus-sc0-delivery/1", "Unsupported SC0 delivery format")
        try require(!blank(manifest.corpusID), "SC0 corpus identity is missing")
        try require(manifest.recordedTextContract == "SceneSnapshot.text(cuts:[])", "Recorded text contract differs")
        try require(manifest.expectedModelTextContract == "manual-design-scene-for-model-section-3", "Expected text contract differs")
        let raw = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        guard let rawCaptures = raw?["captures"] as? [[String: Any]] else {
            throw SceneTextFailure("SC0 capture metadata is missing")
        }
        let captureMetadata = try JSONSerialization.data(
            withJSONObject: rawCaptures, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try require(manifest.privacyReview.captureMetadataSHA256 == hash(captureMetadata),
                    "SC0 capture metadata differs from the privacy review")
        try require(manifest.captures.count == 10, "SC0 requires exactly eight primary and two supplemental captures")
        try require(Set(manifest.captures.map(\.id)).count == 10, "SC0 capture identities must be unique")
        let primary = manifest.captures.filter { $0.role == "primary" }
        let supplements = manifest.captures.filter { $0.role == "supplement" }
        try require(primary.count == 8 && supplements.count == 2, "SC0 primary/supplement roles differ")
        try require(Set(primary.map(\.family)) == families, "SC0 surface families differ")
        try require(Set(supplements.map(\.family)) == ["native-ax-a", "native-ax-b"],
                    "SC0 NativeAX supplement families differ")
        let fixtureIdentities = supplements.compactMap(\.nativeAX).map {
            $0.bundleID + ":" + $0.fixtureSourceSHA256 + ":" + $0.fixtureBinarySHA256
        }
        try require(fixtureIdentities.count == 2 && Set(fixtureIdentities).count == 1,
                    "SC0 supplements must use the same pinned NativeAX fixture")
        try require(manifest.captures.allSatisfy { $0.quality == "complete" }, "SC0 capture quality is not complete")
        try require(Set(manifest.captures.map(\.callID)).count == 10, "SC0 call identities must be unique")
        try require(manifest.instances.path == "instance-checks.json", "SC0 instance file path differs")
        try require(manifest.declaration.path == "corpus-declaration.json", "SC0 declaration path differs")
        let declaration = try decoder.decode(Declaration.self, from: checked(manifest.declaration, under: root))
        try require(declaration.format == "sc0-new-corpus-declaration/1" && declaration.id == manifest.corpusID
                    && Set(declaration.primaryFamilies) == families && declaration.primaryFamilies.count == 8
                    && Set(declaration.supplementaryFamilies) == ["native-ax-a", "native-ax-b"]
                    && declaration.supplementaryFamilies.count == 2,
                    "SC0 preregistered corpus differs")
        guard let registeredAt = instant(declaration.registeredAt) else {
            throw SceneTextFailure("SC0 preregistration timestamp is invalid")
        }
        var files = [manifest.instances.path: manifest.instances.sha256,
                     manifest.declaration.path: manifest.declaration.sha256]
        let instanceData = try checked(manifest.instances, under: root)
        let instances = try decoder.decode(Instances.self, from: instanceData)
        try validate(instances, manifest: manifest, declaration: declaration)
        var primaryCoverages: [Coverage] = []
        var supplementalCoverages: [String: Coverage] = [:]
        let scenes = try manifest.captures.map { capture in
            try require(instant(capture.capturedAt).map { $0 >= registeredAt } == true,
                        "SC0 capture predates preregistration or has an invalid timestamp")
            try require(capture.corpusID == manifest.corpusID, "Capture belongs to another corpus")
            try require(validName(capture.id) && !blank(capture.callID) && !blank(capture.sourceRevision),
                        "Capture identity or source reference is missing")
            try require([capture.binarySHA256, capture.rendererSHA256, capture.rawSceneSHA256,
                         capture.rawTextSHA256].allSatisfy(validSHA256), "Capture provenance digest is invalid")
            let expectedPaths = [capture.id + ".scene.json", capture.id + ".v1.txt", capture.id + ".v2.txt"]
            let references = [capture.scene, capture.recordedText, capture.expectedModelText]
            try require(references.map(\.path) == expectedPaths, "Capture payload paths differ")
            for reference in references {
                try require(files.updateValue(reference.sha256, forKey: reference.path) == nil,
                            "Duplicate SC0 payload path")
            }
            let scene = try decoder.decode(SceneSnapshot.self, from: checked(capture.scene, under: root))
            let bundles = [
                "calculator": "com.apple.calculator", "textedit": "com.apple.TextEdit",
                "reminders": "com.apple.reminders", "preview": "com.apple.Preview",
                "finder": "com.apple.finder", "calendar": "com.apple.iCal"
            ]
            if let bundle = bundles[capture.family] {
                try require(scene.bundleID == bundle, "SC0 family differs from captured app bundle")
            }
            let recorded = try checked(capture.recordedText, under: root)
            let expected = try checked(capture.expectedModelText, under: root)
            try require(recorded == Data(scene.text().utf8), "Recorded scene text differs from snapshot bytes")
            try require(String(data: expected, encoding: .utf8).map { !blank($0) } == true,
                        "Expected model text is empty or not UTF-8")
            let coverage = Coverage(scene)
            try require(coverage == capture.coverage, "Declared SC0 coverage differs from actual snapshot")
            if capture.role == "primary" {
                try require(capture.nativeAX == nil, "Primary capture cannot claim supplemental NativeAX provenance")
                primaryCoverages.append(coverage)
            } else {
                guard let native = capture.nativeAX else { throw SceneTextFailure("NativeAX evidence is missing") }
                try require(native.bundleID == declaration.nativeFixtureBundle && !blank(native.bundleID) && scene.bundleID == native.bundleID
                            && validSHA256(native.fixtureSourceSHA256) && validSHA256(native.fixtureBinarySHA256),
                            "NativeAX fixture identity is invalid")
                try require(native.receipt.path == capture.id + ".native-ax.json", "NativeAX receipt path differs")
                try require(files.updateValue(native.receipt.sha256, forKey: native.receipt.path) == nil,
                            "Duplicate NativeAX receipt path")
                let observed = try decoder.decode(NativeObservation.self, from: checked(native.receipt, under: root))
                try require(observed.format == "braus-sc0-native-ax-observation/1" && observed.source == "native-ax"
                            && observed.callID == capture.callID && observed.bundleID == scene.bundleID
                            && observed.sceneSHA256 == capture.scene.sha256
                            && observed.fixtureSourceSHA256 == native.fixtureSourceSHA256
                            && observed.fixtureBinarySHA256 == native.fixtureBinarySHA256
                            && validSHA256(observed.rawNativeReceiptSHA256)
                            && observed.outOfViewFieldCount == scene.outOfViewFields.count
                            && observed.literalLFObserved == scene.elements.contains { $0.label.contains("\n") }
                            && observed.headingPrefixObserved == coverage.headingPrefixLabel,
                            "NativeAX observation differs from captured facts")
                try require(capture.family != "native-ax-b" || observed.literalLFObserved,
                            "SC0 requires a native multiline label in supplement B")
                supplementalCoverages[capture.family] = coverage
            }
            return GoldenScene(role: capture.role, family: capture.family, name: capture.id, scene: scene, textV1: String(decoding: recorded, as: UTF8.self),
                               textV2: String(decoding: expected, as: UTF8.self))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let payloadNames = Set(names.filter {
            $0.hasSuffix(".scene.json") || $0.hasSuffix(".v1.txt") || $0.hasSuffix(".v2.txt")
        })
        let sceneFiles = manifest.captures.flatMap { [$0.scene.path, $0.recordedText.path, $0.expectedModelText.path] }
        try require(payloadNames == Set(sceneFiles), "SC0 payload inventory differs")
        try require(supplementalCoverages.values.filter(\.outOfView).count == 2,
                    "SC0 requires two out-of-view supplemental scenes")
        try require(supplementalCoverages["native-ax-a"]?.duplicateOutOfViewLabels == true,
                    "SC0 requires duplicate out-of-view labels in supplement A")
        try require(supplementalCoverages["native-ax-b"]?.multilineLabel == true,
                    "SC0 requires a native multiline label in supplement B")
        try require(supplementalCoverages["native-ax-b"]?.headingPrefixLabel == true,
                    "SC0 requires a heading-prefix label in supplement B")
        try require(primaryCoverages.contains(where: \.brainWindow),
                    "SC0 requires nonempty applied Brain window knowledge in a primary scene")
        try positiveObservations(instances, declaration: declaration, captures: manifest.captures,
                                 capturedScenes: Dictionary(uniqueKeysWithValues: scenes.map { ($0.name, $0.scene) }),
                                 root: root, files: &files)
        let observationNames = try Set(FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: "observations").path
        ))
        let referencedObservations = Set(files.keys.filter { $0.hasPrefix("observations/") }
            .map { String($0.dropFirst("observations/".count)) })
        try require(observationNames == referencedObservations, "SC0 auxiliary observation inventory differs")
        let allowedNames = Set(files.keys.filter { !$0.contains("/") })
            .union(["manifest.json", "README.txt", "README.md", "synthetic-v1", "observations"])
        try require(Set(names).isSubset(of: allowedNames), "SC0 delivery contains an unreferenced file")
        let proof = manifest.privacyProof
        try require(proof.status == "passed" && proof.remainingMatches == 0
                    && validSHA256(proof.privateControlSHA256) && validSHA256(proof.policySHA256),
                    "SC0 private privacy check is missing or failed")
        try review(manifest.privacyReview, files: files, reason: "SC0 privacy review is not approved for these bytes")
        try review(manifest.expectedModelTextReview,
                   files: Dictionary(uniqueKeysWithValues: manifest.captures.map {
                       ($0.expectedModelText.path, $0.expectedModelText.sha256)
                   }), reason: "SC0 expected-text review is not approved for these bytes")
        return scenes.sorted { $0.name < $1.name }
    }

    private static func validate(_ instances: Instances, manifest: Manifest, declaration: Declaration) throws {
        try require(instances.format == "braus-sc0-instances/1", "Unsupported SC0 instance format")
        try require(instances.corpusID == manifest.corpusID, "Instance corpus differs from capture corpus")
        try require(instances.sourceSHA256 == manifest.declaration.sha256 && !instances.originalScriptRecovered
                    && !blank(instances.selectionMethod),
                    "Instance selection provenance is missing")
        try require(instances.inputs.count == 25 && instances.fileRoots.count == 5,
                    "SC0 requires exactly 25 inputs and five file roots")
        try require(Set(instances.inputs.map(\.value)).count == 25
                    && instances.inputs.allSatisfy { $0.value.count >= 5 && !blank($0.value) },
                    "SC0 inputs must be distinct nonempty strings of at least five characters")
        try require(Set(instances.fileRoots.map(\.value)).count == 5
                    && instances.fileRoots.allSatisfy { !$0.value.contains("/") && !$0.value.contains("\\") && !blank($0.value) },
                    "SC0 file roots must be five distinct filename stems")
        let items = instances.inputs + instances.fileRoots
        let caseIDs = Set(manifest.captures.map(\.id))
        try require(Set(items.map(\.id)).count == items.count && items.allSatisfy { !blank($0.id) },
                    "SC0 instance identities must be unique")
        try require(items.allSatisfy {
            !$0.caseIDs.isEmpty && !$0.observations.isEmpty
                && Set($0.caseIDs).count == $0.caseIDs.count && Set($0.caseIDs).isSubset(of: caseIDs)
        }, "SC0 instance-to-case association is missing or invalid")
        for (items, declared) in [(instances.inputs, declaration.inputs), (instances.fileRoots, declaration.fileRoots)] {
            try require(items.count == declared.count && Set(items.map(\.id)) == Set(declared.map(\.id)),
                        "SC0 instances differ from preregistration")
            for item in items {
                let registered = declared.first { $0.id == item.id }!
                try require(item.value == registered.value && Set(item.caseIDs).isSubset(of: Set(registered.caseIDs)),
                            "SC0 declared case association differs")
            }
        }
    }

    private static func positiveObservations(
        _ instances: Instances,
        declaration: Declaration,
        captures: [Capture],
        capturedScenes: [String: SceneSnapshot],
        root: URL,
        files: inout [String: String]
    ) throws {
        let decoder = JSONDecoder()
        let registeredAt = instant(declaration.registeredAt)!
        var brainInputMatched = false
        for (items, declared, roots) in [(instances.inputs, declaration.inputs, false),
                                          (instances.fileRoots, declaration.fileRoots, true)] {
            for item in items {
                let registered = declared.first { $0.id == item.id }!
                let aliases = registered.declaredRenderings ?? [registered.value]
                try require(!aliases.isEmpty && aliases.allSatisfy { !blank($0) }, "SC0 declared aliases are missing")
                for observation in item.observations {
                    try require(item.caseIDs.contains(observation.caseID) && !blank(observation.sourceRecordID),
                                "SC0 positive observation case or source record differs")
                    for reference in [observation.scene, observation.receipt] {
                        try require(reference.path.hasPrefix("observations/") && reference.path.split(separator: "/").count == 2,
                                    "SC0 observation path differs")
                        if let previous = files[reference.path] {
                            try require(previous == reference.sha256, "SC0 observation reference digest differs")
                        }
                        files[reference.path] = reference.sha256
                    }
                    let scene = try decoder.decode(SceneSnapshot.self, from: checked(observation.scene, under: root))
                    let receipt = try decoder.decode(ObservationReceipt.self, from: checked(observation.receipt, under: root))
                    try require(receipt.format == "braus-sc0-observation-receipt/1"
                                && receipt.callID == observation.sourceRecordID
                                && receipt.sceneSHA256 == observation.scene.sha256
                                && instant(receipt.capturedAt).map { $0 >= registeredAt } == true
                                && !blank(receipt.sourceRevision)
                                && [receipt.rawSceneSHA256, receipt.binarySHA256, receipt.sourceReceiptSHA256,
                                    receipt.neutralizationProofSHA256].allSatisfy(validSHA256),
                                "SC0 positive observation receipt differs or predates preregistration")
                    guard let capture = captures.first(where: { $0.id == observation.caseID }) else {
                        throw SceneTextFailure("SC0 positive observation case is absent")
                    }
                    try require(scene.bundleID == capturedScenes[observation.caseID]?.bundleID
                                && receipt.binarySHA256 == capture.binarySHA256
                                && receipt.sourceRevision == capture.sourceRevision,
                                "SC0 positive observation belongs to another app or producer")
                    let actual = try field(observation.fieldPath, in: scene)
                    try require(aliases.contains(observation.matchedRendering), "SC0 observation uses an undeclared alias")
                    let found = roots
                        ? folded(URL(fileURLWithPath: actual).deletingPathExtension().lastPathComponent) == folded(item.value)
                        : folded(actual).contains(folded(observation.matchedRendering))
                    try require(found, "SC0 declared instance is absent from the actual observed field")
                    if !roots, capture.role == "primary", receipt.callID == capture.callID,
                       scene == capturedScenes[observation.caseID], Coverage(scene).brainWindow {
                        brainInputMatched = true
                    }
                }
            }
        }
        try require(brainInputMatched, "SC0 requires a declared task input in the same Brain-enriched observation")
    }

    private static func field(_ path: String, in scene: SceneSnapshot) throws -> String {
        let expression = try NSRegularExpression(pattern: #"^(elements|outOfViewFields)\[(0|[1-9][0-9]*)\]\.(label|value)$"#)
        let string = path as NSString
        guard let match = expression.firstMatch(in: path, range: NSRange(location: 0, length: string.length)),
              let index = Int(string.substring(with: match.range(at: 2))) else {
            throw SceneTextFailure("SC0 positive observation field path is invalid")
        }
        let collection = string.substring(with: match.range(at: 1))
        let member = string.substring(with: match.range(at: 3))
        let result: String?
        if collection == "elements", scene.elements.indices.contains(index) {
            result = member == "label" ? scene.elements[index].label : scene.elements[index].value
        } else if collection == "outOfViewFields", scene.outOfViewFields.indices.contains(index) {
            result = member == "label" ? scene.outOfViewFields[index].label : scene.outOfViewFields[index].value
        } else { result = nil }
        guard let result else { throw SceneTextFailure("SC0 positive observation field is absent") }
        return result
    }

    private static func folded(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCompatibilityMapping
    }

    private static func instant(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func review(_ review: Review, files: [String: String], reason: String) throws {
        try require(review.filesSHA256 == files, "SC0 review payload hashes differ")
        try require(review.status == "approved" && !blank(review.reviewer), reason)
    }

    private static func checked(_ reference: FileReference, under root: URL) throws -> Data {
        try require(validSHA256(reference.sha256), "Payload digest is invalid")
        let bytes = try read(reference.path, under: root)
        try require(hash(bytes) == reference.sha256, "SC0 payload hash differs: \(reference.path)")
        return bytes
    }

    private static func read(_ name: String, under root: URL) throws -> Data {
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        try require(!components.isEmpty && components.allSatisfy(validName), "SC0 payload path is invalid")
        var url = root
        for component in components {
            url.append(path: component)
            let part = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            try require(part.isSymbolicLink != true, "SC0 payload must not traverse a symbolic link")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true,
                    "SC0 payload must be a regular file, not a symbolic link")
        return try Data(contentsOf: url)
    }

    private static func validName(_ value: String) -> Bool {
        !blank(value) && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func blank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SceneTextFailure(message) }
    }
}
