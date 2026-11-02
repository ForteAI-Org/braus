import Memory
import PerceptionCore
import Testing

struct ValueMinimizationTests {
    @Test(arguments: ["sk-test-CANARY0123456789abcdefXYZ", "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6"])
    func credentialTextKeepsItsReason(credential: String) {
        let minimization = ValueMinimization()
        let (text, reason) = minimization.minimize(text: "key \(credential)", typedInto: "Notes")
        #expect(text == "key [withheld]")
        #expect(reason == .credentialPattern)
        let (effect, effectReason) = minimization.minimize(effect: .valueChanged(label: "Key \(credential)", value: "x"))
        #expect(effect == .valueChanged(label: "Key [withheld]", value: "x"))
        #expect(effectReason == .credentialPattern)
    }

    @Test(arguments: [("Password", "ordinary"), ("PIN", "1234"), ("Token", "Ab3!Cd4?Ef5@")])
    func fieldSignalsWithholdTheWholeValue(label: String, value: String) {
        let (text, reason) = ValueMinimization().minimize(text: value, typedInto: label)
        #expect(text == "[withheld]")
        #expect(reason == .secretTarget)
    }

    @Test(arguments: [("Key", "C major"), ("Token", "abc"), ("PIN", "Off")])
    func ordinaryWeakLabelsRemainVisible(label: String, value: String) {
        let (text, reason) = ValueMinimization().minimize(text: value, typedInto: label)
        #expect(text == value)
        #expect(reason == nil)
    }
}
