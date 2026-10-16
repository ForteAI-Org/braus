import Testing
import PerceptionCore
@testable import AccessibilityFacts

@Suite("Native button state")
struct NativeButtonStateTests {

    @Test("Pro Tools Mute reads the Mix and Edit on values", arguments: ["on", "on state"])
    func proToolsMuteOn(value: String) {
        #expect(read(value: value) == .on)
    }

    @Test("a successful empty Mute value is off")
    func proToolsMuteOff() {
        #expect(read(value: "") == .off)
    }

    @Test("missing and unrecognized Mute values stay unknown",
          arguments: [nil, "off", "1", "ON", " ", "unknown"] as [String?])
    func unknownMuteValue(value: String?) {
        #expect(read(value: value) == nil)
    }

    @Test("Pro Tools Mute does not use AXSelected as a substitute for its value")
    func muteUsesItsValue() {
        #expect(read(value: "", selected: true) == .off)
        #expect(read(value: nil, selected: true) == nil)
    }

    @Test("other controls and applications do not inherit Pro Tools Mute semantics",
          arguments: ["", "on", "on state"])
    func unrelatedButtons(value: String) {
        #expect(read(value: value, bundleID: "test.app") == nil)
        #expect(read(value: value, bundleID: nil) == nil)
        #expect(read(value: value, identifier: "record") == nil)
        #expect(read(value: value, identifier: nil) == nil)
        #expect(read(value: value, identifier: "Mute") == nil)
    }

    @Test("Pro Tools Solo reads its native value independently of AXSelected")
    func proToolsSolo() {
        #expect(read(value: "Selected", identifier: "solo") == .on)
        #expect(read(value: "on", identifier: "solo") == .on)
        #expect(read(value: "", identifier: "solo") == .off)
        #expect(read(value: "", identifier: "solo", selected: true) == .off)
        for value in [nil, "on state", "selected", "unknown"] as [String?] {
            #expect(read(value: value, identifier: "solo", selected: true) == nil)
        }
        #expect(read(value: "Selected", bundleID: "test.app", identifier: "solo") == nil)
        #expect(read(value: "Selected", identifier: "mute") == nil)
    }

    @Test("ordinary selected buttons keep their native on state")
    func standardSelection() {
        #expect(read(value: nil, bundleID: "test.app", selected: true) == .on)
        #expect(read(value: "", bundleID: "test.app", selected: false) == nil)
        #expect(read(value: "", bundleID: "test.app", selected: nil) == nil)
    }

    private func read(
        value     : String?,
        bundleID  : String? = "com.avid.ProTools",
        identifier: String? = "mute",
        selected  : Bool? = false
    ) -> ControlState? {
        NativeButtonState.read(
            bundleID  : bundleID,
            identifier: identifier,
            value     : value,
            isSelected: selected
        )
    }
}
