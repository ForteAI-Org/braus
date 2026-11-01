import Memory
import Testing

/// SensitivityCostTests reports fixed-input costs; run alone with --no-parallel for comparisons.
@Suite(.serialized)
struct SensitivityCostTests {
    @Test func fixedMessages() {
        let classifier = SensitivityClassifier()
        let messages: [(name: String, text: String, findings: Int)] = [
            ("ordinary", "A normal message without a credential.", 0),
            ("card", "A normal message with a synthetic card 4111 1111 1111 1111.", 1),
            ("declaration", "la password è Xy9#kq2!pL", 1),
            ("longOrdinary", String(repeating: "A normal message with ordinary words. ", count: 32), 0)
        ]
        let clock = ContinuousClock()
        for message in messages {
            for constructsClassifier in [false, true] {
                var samples: [Double] = []
                var found = 0
                _ = classifier.findings(in: message.text, field: .init())
                for _ in 0..<300 {
                    let start = clock.now
                    let active = constructsClassifier ? SensitivityClassifier() : classifier
                    found += active.findings(in: message.text, field: .init()).count
                    let elapsed = start.duration(to: clock.now).components
                    samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                }
                #expect(found == message.findings * 300)
                let ordered = samples.sorted()
                print("Sensitivity message cost: input=\(message.name), bytes=\(message.text.utf8.count), "
                    + "constructsClassifier=\(constructsClassifier), samples=\(samples.count), "
                    + "p50Milliseconds=\(ordered[149]), p95Milliseconds=\(ordered[284])")
            }
        }
    }
    @Test func minimizedMessageCost() {
        let text = String(repeating: "A normal message with ordinary words. ", count: 32)
        #expect(text.utf8.count == 1_216)
        let minimization = ValueMinimization()
        let clock = ContinuousClock()
        _ = minimization.minimize(text: text)
        var samples: [Double] = []
        for _ in 0..<1_000 {
            let start = clock.now
            let result = minimization.minimize(text: text)
            let elapsed = start.duration(to: clock.now).components
            #expect(result.0 == text && result.1 == nil)
            samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        samples.sort()
        print("Sensitivity minimization cost: bytes=\(text.utf8.count), samples=\(samples.count), "
            + "p50Milliseconds=\(samples[499]), p95Milliseconds=\(samples[949])")
    }

}
