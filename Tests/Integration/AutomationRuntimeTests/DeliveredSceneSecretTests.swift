import AutomationRuntime
import CoreGraphics
import Memory
import Perception
import PerceptionCore
import Synchronization
import Testing

/// A controlled native tree exercises the same harvest and merge used by both scene readers.
struct DeliveredSceneSecretTests {
    private struct Reader: AccessibilityTreeReading {
        let guardValue: ValueGuard
        let fields = [("Token", "eyJabcdefgh.abcdefgh.abcdefgh"),
                      ("Account", "GB82 WEST 1234 5698 7654 32"), ("Key", "C major")]

        func role(_ node: Int) -> String? { node == 0 ? "AXWindow" : "AXTextField" }
        func subrole(_ node: Int) -> String? { "" }
        func title(_ node: Int) -> String? { node == 0 ? nil : fields[node - 1].0 }
        func descriptionText(_ node: Int) -> String? { nil }
        func identifier(_ node: Int) -> String? { nil }
        var requiresValueClassification: Bool { true }
        func value(_ node: Int) -> String? {
            AccessibilityValueReading.readText(guard: guardValue, attribute: { name in
                switch name {
                case "AXRole": role(node)
                case "AXSubrole": subrole(node)
                case "AXTitle": title(node)
                default: nil
                }
            }, value: { node == 0 ? nil : fields[node - 1].1 })
        }
        func numericValue(_ node: Int) -> Int? { nil }
        func isEnabled(_ node: Int) -> Bool? { true }
        func actions(_ node: Int) -> [String] { [] }
        func frame(_ node: Int) -> CGRect? {
            node == 0 ? CGRect(x: 0, y: 0, width: 400, height: 300)
                      : CGRect(x: 10, y: node * 40, width: 200, height: 25)
        }
        func children(_ node: Int) -> [Int] { node == 0 ? [1, 2, 3] : [] }
    }

    private struct Text: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] { [] }
    }

    private struct Augmentation: SceneAugmenting {
        let reader: Reader

        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest {
            AccessibilityAugmentation.harvest(under: 0, windowFrame: windowFrame, reader: reader)
        }
    }

    @Test(arguments: [false, true])
    func deliveredScene(human: Bool) async throws {
        let guardValue = human ? SensitivityClassifier().valueGuard : ProductionPerception.workerValueGuard
        let reader = Reader(guardValue: guardValue)
        let samples = Mutex<[Double]>([])
        let pipeline = ScenePipeline(text: Text(), augmentation: Augmentation(reader: reader), timingHook: { stage, elapsed in
            if stage == .augmentation {
                let parts = elapsed.components
                samples.withLock { $0.append(Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15) }
            }
        })
        let context = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let window = ScenePipeline.Window(bundleID: "example.fixture", appName: "Fixture", title: "Form",
                                           processID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        for _ in 0..<100 {
            let capture = try await pipeline.capture(image, of: window)
            let scene = capture.scene
            #expect(capture.quality.walkCompleted == true)
            #expect(scene.elements.contains { $0.value == "C major" })
            for secret in ["eyJabcdefgh.abcdefgh.abcdefgh", "GB82 WEST 1234 5698 7654 32"] {
                #expect(!scene.elements.contains { $0.value == secret })
                #expect(!scene.text().contains(secret))
                #expect(!scene.mapText().contains(secret))
            }
        }
        let ordered = samples.withLock { $0.sorted() }
        #expect(ordered.count == 100)
        if ordered.count == 100 {
            print("Sensitivity controlled three-field scene augmentation p95 milliseconds (human=\(human)): \(ordered[94])")
        }
    }
}
