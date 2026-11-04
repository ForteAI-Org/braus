import CryptoKit
import Foundation
import PerceptionCore
import Testing

/// SceneTextDeliveryValidationTests exercise acceptance and rejection using temporary synthetic inputs.
/// Review states simulate validator inputs only; they never attest a capture or a human approval.
struct SceneTextDeliveryValidationTests {
    private enum InvalidDelivery: CaseIterable, Equatable, Sendable {
        case format, nineCaptures, duplicateFamily, duplicateCall, unsafePath, payloadHash
        case falseCoverage, noBrain, oneOutOfView, fewerInputs, duplicateRoots, unknownAssociation
        case unboundCase, otherCorpus, noPrivacyProof, emptyExpected, unreviewed, symlink, reviewHashes
        case elevenCaptures, wrongRole, wrongSupplementFamily, incompletePrimary, nonNativeSupplement
        case nativeReceiptMismatch, missingLF, missingDuplicate
        case noPositiveObservations, undeclaredAlias, absentPositiveValue, positiveReceiptMismatch
        case observationBeforeRegistration, captureBeforeRegistration, invalidField, unobservedBrainInput
        case normalizedAlias, changedPreregFingerprint, rootSubstringOnly

        var message: String {
            switch self {
            case .format: "Unsupported SC0 delivery format"
            case .nineCaptures: "exactly eight primary and two supplemental captures"
            case .duplicateFamily: "surface families differ"
            case .duplicateCall: "call identities must be unique"
            case .unsafePath: "payload paths differ"
            case .payloadHash: "payload hash differs"
            case .falseCoverage: "coverage differs from actual snapshot"
            case .noBrain: "nonempty applied Brain"
            case .oneOutOfView: "two out-of-view supplemental scenes"
            case .fewerInputs: "exactly 25 inputs"
            case .duplicateRoots: "five distinct filename stems"
            case .unknownAssociation: "association is missing or invalid"
            case .unboundCase: "declared case association differs"
            case .otherCorpus: "Instance corpus differs"
            case .noPrivacyProof: "privacy check is missing or failed"
            case .emptyExpected: "Expected model text is empty"
            case .unreviewed: "privacy review is not approved"
            case .symlink: "symbolic link"
            case .reviewHashes: "review payload hashes differ"
            case .elevenCaptures: "exactly eight primary and two supplemental captures"
            case .wrongRole: "primary/supplement roles differ"
            case .wrongSupplementFamily: "NativeAX supplement families differ"
            case .incompletePrimary: "capture quality is not complete"
            case .nonNativeSupplement: "same pinned NativeAX fixture"
            case .nativeReceiptMismatch: "NativeAX observation differs"
            case .missingLF: "native multiline label in supplement B"
            case .missingDuplicate: "duplicate out-of-view labels in supplement A"
            case .noPositiveObservations: "association is missing or invalid"
            case .undeclaredAlias: "undeclared alias"
            case .absentPositiveValue, .rootSubstringOnly: "absent from the actual observed field"
            case .positiveReceiptMismatch, .observationBeforeRegistration: "observation receipt differs"
            case .captureBeforeRegistration: "capture predates preregistration"
            case .invalidField: "observation field is absent"
            case .unobservedBrainInput: "same Brain-enriched observation"
            case .normalizedAlias: "privacy review is not approved"
            case .changedPreregFingerprint: "selection provenance is missing"
            }
        }
    }

    @Test(arguments: InvalidDelivery.allCases)
    private func invalidDeliveryIsRejected(_ invalid: InvalidDelivery) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var (manifest, instances) = try syntheticUnreviewedDelivery(at: root)
        var captures = manifest["captures"] as! [[String: Any]]
        switch invalid {
        case .format:
            manifest["format"] = "unsupported"
        case .captureBeforeRegistration:
            captures[0]["capturedAt"] = "1999-12-31T00:00:00Z"
        case .changedPreregFingerprint:
            instances["sourceSHA256"] = digest(Data("wrong declaration".utf8))
        case .noPositiveObservations, .undeclaredAlias, .absentPositiveValue, .positiveReceiptMismatch,
             .observationBeforeRegistration, .invalidField, .unobservedBrainInput, .normalizedAlias, .rootSubstringOnly:
            let key = invalid == .rootSubstringOnly ? "fileRoots" : "inputs"
            let index = invalid == .unobservedBrainInput || invalid == .rootSubstringOnly ? 0 : 1
            var items = instances[key] as! [[String: Any]]
            var observations = items[index]["observations"] as! [[String: Any]]
            if invalid == .noPositiveObservations {
                observations = []
            } else {
                var observation = observations[0]
                if invalid == .undeclaredAlias { observation["matchedRendering"] = "undeclared replacement" }
                if invalid == .positiveReceiptMismatch { observation["sourceRecordID"] = "different-call" }
                if invalid == .invalidField { observation["fieldPath"] = "elements[9999].value" }
                var sceneReference = observation["scene"] as! [String: String]
                var receiptReference = observation["receipt"] as! [String: String]
                let receiptURL = root.appending(path: receiptReference["path"]!)
                var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
                if invalid == .absentPositiveValue || invalid == .normalizedAlias || invalid == .rootSubstringOnly {
                    let url = root.appending(path: sceneReference["path"]!)
                    var scene = try JSONDecoder().decode(SceneSnapshot.self, from: Data(contentsOf: url))
                    scene.elements[0].value = invalid == .normalizedAlias ? "ＩＮＰＵＴ-ＶＡＬＵＥ-１"
                        : (invalid == .rootSubstringOnly ? "prefix-file-value-0.txt" : "Other actual value")
                    let bytes = try JSONEncoder().encode(scene)
                    try bytes.write(to: url)
                    sceneReference["sha256"] = digest(bytes)
                    receipt["scene_sha256"] = digest(bytes)
                }
                if invalid == .observationBeforeRegistration { receipt["captured_at"] = "1999-12-31T00:00:00Z" }
                if invalid == .unobservedBrainInput {
                    receipt["call_id"] = "another-observation"
                    observation["sourceRecordID"] = "another-observation"
                }
                let receiptBytes = try encode(receipt)
                try receiptBytes.write(to: receiptURL)
                receiptReference["sha256"] = digest(receiptBytes)
                observation["scene"] = sceneReference
                observation["receipt"] = receiptReference
                observations[0] = observation
            }
            items[index]["observations"] = observations
            instances[key] = items
        case .nineCaptures:
            captures.removeLast()
        case .elevenCaptures:
            captures.append(captures[0])
        case .wrongRole:
            captures[0]["role"] = "supplement"
        case .wrongSupplementFamily:
            captures[8]["family"] = "arbitrary-extra-window"
        case .incompletePrimary:
            captures[0]["quality"] = "partial"
        case .nonNativeSupplement:
            captures[8].removeValue(forKey: "nativeAX")
        case .nativeReceiptMismatch:
            var native = captures[8]["nativeAX"] as! [String: Any]
            var reference = native["receipt"] as! [String: String]
            let url = root.appending(path: reference["path"]!)
            var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            receipt["outOfViewFieldCount"] = 999
            let bytes = try encode(receipt)
            try bytes.write(to: url)
            reference["sha256"] = digest(bytes)
            native["receipt"] = reference
            captures[8]["nativeAX"] = native
        case .missingLF, .missingDuplicate:
            let index = invalid == .missingLF ? 9 : 8
            let url = root.appending(path: "case-\(index).scene.json")
            var scene = try JSONDecoder().decode(SceneSnapshot.self, from: Data(contentsOf: url))
            if invalid == .missingLF {
                scene.elements[0].label = "## Folder A Folder B"
            } else {
                scene.outOfViewFields[1].label = "Other field"
            }
            captures[index] = try rewrite(scene, capture: captures[index], at: root)
        case .duplicateFamily:
            captures[1]["family"] = captures[0]["family"]
        case .duplicateCall:
            captures[1]["callID"] = captures[0]["callID"]
        case .unsafePath:
            captures[0]["scene"] = ["path": "../outside.scene.json", "sha256": digest(Data())]
        case .payloadHash:
            try Data("changed".utf8).write(to: root.appending(path: "case-0.scene.json"))
        case .falseCoverage:
            var coverage = captures[8]["coverage"] as! [String: Bool]
            coverage["outOfView"] = false
            captures[8]["coverage"] = coverage
        case .noBrain, .oneOutOfView:
            let index = invalid == .noBrain ? 0 : 8
            let url = root.appending(path: "case-\(index).scene.json")
            var scene = try JSONDecoder().decode(SceneSnapshot.self, from: Data(contentsOf: url))
            if invalid == .noBrain { scene.knowledge = nil } else { scene.outOfViewFields = [] }
            captures[index] = try rewrite(scene, capture: captures[index], at: root)
        case .fewerInputs:
            var inputs = instances["inputs"] as! [[String: Any]]
            inputs.removeLast()
            instances["inputs"] = inputs
        case .duplicateRoots:
            var roots = instances["fileRoots"] as! [[String: Any]]
            roots[1]["value"] = roots[0]["value"]
            instances["fileRoots"] = roots
        case .unknownAssociation:
            var inputs = instances["inputs"] as! [[String: Any]]
            inputs[0]["caseIDs"] = ["not-delivered"]
            instances["inputs"] = inputs
        case .unboundCase:
            for key in ["inputs", "fileRoots"] {
                var items = instances[key] as! [[String: Any]]
                for index in items.indices { items[index]["caseIDs"] = ["case-0"] }
                instances[key] = items
            }
        case .otherCorpus:
            instances["corpusID"] = "other-synthetic-corpus"
        case .noPrivacyProof:
            var proof = manifest["privacyProof"] as! [String: Any]
            proof["remainingMatches"] = 1
            manifest["privacyProof"] = proof
        case .emptyExpected:
            let file = "case-0.v2.txt"
            try Data().write(to: root.appending(path: file))
            captures[0]["expectedModelText"] = ["path": file, "sha256": digest(Data())]
        case .unreviewed, .reviewHashes:
            break
        case .symlink:
            let original = root.appending(path: "case-0.scene.json")
            let target = root.appending(path: "symlink-target.json")
            try FileManager.default.moveItem(at: original, to: target)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
        }
        manifest["captures"] = captures
        try writeSyntheticManifest(&manifest, instances: instances, at: root,
                                   pending: invalid == .unreviewed || invalid == .normalizedAlias,
                                   corruptReviewHashes: invalid == .reviewHashes)
        do {
            _ = try GoldenScene.all(at: root)
            Issue.record("An invalid or unreviewed synthetic delivery was accepted")
        } catch let failure as SceneTextFailure {
            #expect(failure.description.contains(invalid.message), "\(failure.description)")
        }
    }

    @Test
    func emptyMetadataDoesNotBecomeAnEmptyOrAcceptedCorpus() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appending(path: "manifest.json"))
        #expect(throws: DecodingError.self) { try GoldenScene.all(at: root) }
    }

    @Test
    func structurallyValidTemporarySyntheticDeliveryIsAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var (manifest, instances) = try syntheticUnreviewedDelivery(at: root)
        try writeSyntheticManifest(&manifest, instances: instances, at: root)
        let scenes = try GoldenScene.all(at: root)
        #expect(scenes.count == 10)
        #expect(scenes.filter { $0.role == "primary" }.count == 8)
        #expect(scenes.filter { $0.role == "supplement" }.count == 2)
        #expect(Set(scenes.map(\.family)).count == 10)
        #expect(scenes.allSatisfy { $0.textV2 != $0.scene.text(cuts: .safe) })
    }

    @Test(arguments: ["callID", "capturedAt"])
    func captureMetadataCannotChangeAfterReview(_ field: String) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var (manifest, instances) = try syntheticUnreviewedDelivery(at: root)
        try writeSyntheticManifest(&manifest, instances: instances, at: root)
        var captures = manifest["captures"] as! [[String: Any]]
        captures[7][field] = field == "callID" ? "changed-after-review" : "2000-02-01T00:00:00Z"
        manifest["captures"] = captures
        try encode(manifest).write(to: root.appending(path: "manifest.json"))
        do {
            _ = try GoldenScene.all(at: root)
            Issue.record("Capture metadata changed after review was accepted")
        } catch let failure as SceneTextFailure {
            #expect(failure.description.contains("capture metadata differs"))
        }
    }

    /// Writes simulated review states only for this test's temporary, explicitly synthetic corpus.
    private func writeSyntheticManifest(
        _ manifest: inout [String: Any],
        instances: [String: Any],
        at root: URL,
        pending: Bool = false,
        corruptReviewHashes: Bool = false
    ) throws {
        precondition(manifest["corpusID"] as? String == "synthetic-validator-only")
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        precondition(root.resolvingSymlinksInPath().path.hasPrefix(temporary))
        let captures = manifest["captures"] as! [[String: Any]]
        let bytes = try encode(instances)
        try bytes.write(to: root.appending(path: "instance-checks.json"))
        manifest["instances"] = ["path": "instance-checks.json", "sha256": digest(bytes)]
        var payloadHashes = ["instance-checks.json": digest(bytes)]
        let declared = manifest["declaration"] as! [String: String]
        payloadHashes[declared["path"]!] = declared["sha256"]!
        for key in ["inputs", "fileRoots"] {
            for item in instances[key] as! [[String: Any]] {
                for observation in item["observations"] as! [[String: Any]] {
                    for field in ["scene", "receipt"] {
                        let reference = observation[field] as! [String: String]
                        payloadHashes[reference["path"]!] = reference["sha256"]!
                    }
                }
            }
        }
        for capture in captures {
            for key in ["scene", "recordedText", "expectedModelText"] {
                let reference = capture[key] as! [String: String]
                payloadHashes[reference["path"]!] = reference["sha256"]!
            }
            if let native = capture["nativeAX"] as? [String: Any], let receipt = native["receipt"] as? [String: String] {
                payloadHashes[receipt["path"]!] = receipt["sha256"]!
            }
        }
        var privacyReview = manifest["privacyReview"] as! [String: Any]
        privacyReview["filesSHA256"] = corruptReviewHashes ? [:] : payloadHashes
        privacyReview["captureMetadataSHA256"] = digest(try JSONSerialization.data(
            withJSONObject: captures, options: [.sortedKeys, .withoutEscapingSlashes]
        ))
        privacyReview["status"] = pending ? "pending" : "approved"
        privacyReview["reviewer"] = pending ? "" : "Synthetic validator test, not a human approval"
        manifest["privacyReview"] = privacyReview
        var expectedHashes: [String: String] = [:]
        for capture in captures {
            let reference = capture["expectedModelText"] as! [String: String]
            expectedHashes[reference["path"]!] = reference["sha256"]!
        }
        manifest["expectedModelTextReview"] = [
            "status": pending ? "pending" : "approved",
            "reviewer": pending ? "" : "Synthetic validator test, not a human approval",
            "filesSHA256": expectedHashes
        ]
        try encode(manifest).write(to: root.appending(path: "manifest.json"))
    }

    private func syntheticUnreviewedDelivery(at root: URL) throws -> ([String: Any], [String: Any]) {
        let families = ["calculator", "textedit", "save", "open", "reminders",
                        "preview", "finder", "calendar", "native-ax-a", "native-ax-b"]
        let bundles = ["com.apple.calculator", "com.apple.TextEdit", "com.example.dialog", "com.example.dialog",
                       "com.apple.reminders", "com.apple.Preview", "com.apple.finder", "com.apple.iCal",
                       "com.example.native-ax-validator", "com.example.native-ax-validator"]
        let captures: [[String: Any]] = try families.enumerated().map { index, family in
            let field = SceneElement(id: "field", kind: .text,
                                     label: index == 9 ? "## Folder A\nFolder B" : (index == 0 ? "input-value-0" : "Folder A"),
                                     bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.1))
            let scene = SceneSnapshot(
                bundleID: bundles[index], appName: "Synthetic validator input", windowTitle: "Folder A",
                viewportPixelSize: .init(width: 1000, height: 800), elements: [field],
                outOfViewFields: index == 8 || index == 9
                    ? [.init(label: "Field", value: "A", role: "AXTextField"),
                       .init(label: "Field", value: "B", role: "AXTextField")] : [],
                knowledge: index == 0 ? SceneKnowledge(status: .applied, window: ["Synthetic operation"]) : nil
            )
            let capture: [String: Any] = [
                "id": "case-\(index)", "family": family, "role": index < 8 ? "primary" : "supplement",
                "quality": "complete", "corpusID": "synthetic-validator-only",
                "callID": "synthetic-call-\(index)", "capturedAt": "2000-01-02T00:00:00Z", "sourceRevision": "synthetic-not-a-real-capture",
                "binarySHA256": digest(Data("synthetic binary".utf8)),
                "rendererSHA256": digest(Data("synthetic renderer".utf8)),
                "rawSceneSHA256": digest(Data("synthetic raw scene".utf8)),
                "rawTextSHA256": digest(Data("synthetic raw text".utf8))
            ]
            return try rewrite(scene, capture: capture, at: root)
        }
        try FileManager.default.createDirectory(at: root.appending(path: "observations"), withIntermediateDirectories: false)
        func items(_ count: Int, prefix: String) throws -> [[String: Any]] {
            try (0..<count).map { index in
                let caseID = "case-\(index % 10)"
                let value = "\(prefix)-value-\(index)"
                let sameBrainObservation = prefix == "input" && index == 0
                let sceneURL = root.appending(path: caseID + ".scene.json")
                var scene = try JSONDecoder().decode(SceneSnapshot.self, from: Data(contentsOf: sceneURL))
                if !sameBrainObservation {
                    scene.elements[0].value = prefix == "file" ? value + ".txt"
                        : (index == 1 ? "ＩＮＰＵＴ-ＶＡＬＵＥ-１" : value)
                }
                let fieldPath = sameBrainObservation ? "elements[0].label" : "elements[0].value"
                let sceneBytes = try JSONEncoder().encode(scene)
                let scenePath = "observations/\(prefix)-\(index).scene.json"
                try sceneBytes.write(to: root.appending(path: scenePath))
                let callID = sameBrainObservation ? "synthetic-call-0" : "synthetic-positive-\(prefix)-\(index)"
                let receipt: [String: Any] = [
                    "format": "braus-sc0-observation-receipt/1", "call_id": callID,
                    "captured_at": "2000-01-02T00:00:00Z", "scene_sha256": digest(sceneBytes),
                    "raw_scene_sha256": digest(Data("synthetic raw observation".utf8)),
                    "binary_sha256": digest(Data("synthetic binary".utf8)),
                    "source_revision": "synthetic-not-a-real-capture",
                    "source_receipt_sha256": digest(Data("synthetic source receipt".utf8)),
                    "neutralization_proof_sha256": digest(Data("synthetic transformation".utf8))
                ]
                let receiptBytes = try encode(receipt)
                let receiptPath = "observations/\(prefix)-\(index).receipt.json"
                try receiptBytes.write(to: root.appending(path: receiptPath))
                return ["id": "\(prefix)-\(index)", "value": value, "caseIDs": [caseID],
                        "observations": [["caseID": caseID, "sourceRecordID": callID,
                            "scene": ["path": scenePath, "sha256": digest(sceneBytes)],
                            "receipt": ["path": receiptPath, "sha256": digest(receiptBytes)],
                            "fieldPath": fieldPath, "matchedRendering": value]]]
            }
        }
        let inputItems = try items(25, prefix: "input")
        let rootItems = try items(5, prefix: "file")
        func declared(_ items: [[String: Any]]) -> [[String: Any]] {
            items.map { ["id": $0["id"]!, "value": $0["value"]!, "case_ids": $0["caseIDs"]!,
                         "declared_renderings": [$0["value"]!]] }
        }
        let declaration: [String: Any] = [
            "format": "sc0-new-corpus-declaration/1", "id": "synthetic-validator-only",
            "registered_at": "2000-01-01T00:00:00Z", "primary_families": Array(families.prefix(8)),
            "supplementary_families": ["native-ax-a", "native-ax-b"],
            "native_fixture_bundle": "com.example.native-ax-validator", "inputs": declared(inputItems),
            "file_roots": declared(rootItems)
        ]
        let declarationBytes = try encode(declaration)
        try declarationBytes.write(to: root.appending(path: "corpus-declaration.json"))
        let instances: [String: Any] = [
            "format": "braus-sc0-instances/1", "corpusID": "synthetic-validator-only",
            "sourceSHA256": digest(declarationBytes),
            "selectionMethod": "Synthetic negative validator input, not a historical selection",
            "originalScriptRecovered": false, "inputs": inputItems,
            "fileRoots": rootItems
        ]
        let pendingReview: [String: Any] = ["status": "pending", "reviewer": "", "filesSHA256": [:]]
        let manifest: [String: Any] = [
            "format": "braus-sc0-delivery/1", "corpusID": "synthetic-validator-only",
            "recordedTextContract": "SceneSnapshot.text(cuts:[])",
            "expectedModelTextContract": "manual-design-scene-for-model-section-3", "captures": captures,
            "declaration": ["path": "corpus-declaration.json", "sha256": digest(declarationBytes)],
            "privacyProof": ["status": "passed", "remainingMatches": 0,
                             "privateControlSHA256": digest(Data("synthetic control".utf8)),
                             "policySHA256": digest(Data("synthetic policy".utf8))],
            "privacyReview": pendingReview, "expectedModelTextReview": pendingReview
        ]
        return (manifest, instances)
    }

    private func rewrite(_ scene: SceneSnapshot, capture: [String: Any], at root: URL) throws -> [String: Any] {
        var capture = capture
        let id = capture["id"] as! String
        let payloads = [
            ("scene", id + ".scene.json", try JSONEncoder().encode(scene)),
            ("recordedText", id + ".v1.txt", Data(scene.text().utf8)),
            ("expectedModelText", id + ".v2.txt", Data("Synthetic unreviewed future-format placeholder\n".utf8))
        ]
        for (key, name, bytes) in payloads {
            try bytes.write(to: root.appending(path: name))
            capture[key] = ["path": name, "sha256": digest(bytes)]
        }
        let labels = scene.outOfViewFields.map(\.label)
        capture["coverage"] = [
            "outOfView": !labels.isEmpty, "duplicateOutOfViewLabels": Set(labels).count < labels.count,
            "multilineLabel": scene.elements.contains { $0.label.contains("\n") || $0.label.contains("\r") },
            "headingPrefixLabel": scene.elements.contains { $0.label.hasPrefix("## ") },
            "brainWindow": scene.knowledge?.status == .applied && scene.knowledge?.window.isEmpty == false
        ]
        if capture["role"] as? String == "supplement" {
            let fixtureSource = digest(Data("synthetic fixture source".utf8))
            let fixtureBinary = digest(Data("synthetic fixture binary".utf8))
            let sceneReference = capture["scene"] as! [String: String]
            let receipt: [String: Any] = [
                "format": "braus-sc0-native-ax-observation/1", "source": "native-ax",
                "callID": capture["callID"]!, "bundleID": scene.bundleID,
                "sceneSHA256": sceneReference["sha256"]!, "fixtureSourceSHA256": fixtureSource,
                "fixtureBinarySHA256": fixtureBinary, "rawNativeReceiptSHA256": digest(Data("synthetic native receipt".utf8)),
                "outOfViewFieldCount": scene.outOfViewFields.count,
                "literalLFObserved": scene.elements.contains { $0.label.contains("\n") },
                "headingPrefixObserved": scene.elements.contains { $0.label.hasPrefix("## ") }
            ]
            let receiptBytes = try encode(receipt)
            let receiptName = id + ".native-ax.json"
            try receiptBytes.write(to: root.appending(path: receiptName))
            capture["nativeAX"] = [
                "bundleID": scene.bundleID, "fixtureSourceSHA256": fixtureSource,
                "fixtureBinarySHA256": fixtureBinary,
                "receipt": ["path": receiptName, "sha256": digest(receiptBytes)]
            ]
        }
        return capture
    }

    private func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
