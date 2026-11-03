import EngineCore
import PerceptionCore
import Testing

struct ScreenExpectationTests {
    @Test func windowReadingsRetainTheirMeaning() {
        let expected = ScreenExpectation.window(title: "Export", open: true)
        #expect(expected.judge(windows: ["Export file"], scene: nil).verdict == .passed)
        #expect(expected.judge(windows: [], scene: nil).verdict == .failed)
        #expect(expected.judge(windows: nil, scene: nil).verdict == .failed)
        #expect(ScreenExpectation.element(label: "Name", expect: .present)
            .judge(windows: nil, scene: nil).verdict == .unknown)
    }
}

extension ScreenExpectationTests {
    @Test func secureValuesCannotBeCompared() {
        for value in ["fake-secret", "wrong"] {
            let scene = SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "Panel",
                viewportPixelSize: .init(width: 100, height: 100), elements: [
                    SceneElement(id: "password", kind: .control, label: "Password",
                        bounds: .init(x: 0, y: 0, width: 1, height: 1), role: "AXSecureTextField", value: "fake-secret")])
            #expect(ScreenExpectation.element(label: "Password", expect: .value(value))
                .judge(windows: nil, scene: scene).verdict == .unknown)
        }
    }
}

extension ScreenExpectationTests {
    @Test func withheldValuesCannotBeCompared() {
        let scene = SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "Panel",
            viewportPixelSize: .init(width: 100, height: 100), elements: [
                SceneElement(id: "field", kind: .control, label: "Field",
                    bounds: .init(x: 0, y: 0, width: 1, height: 1), value: "private-value")])
        ScreenExpectation.$valueIsReadable.withValue({ $0 != "private-value" }) {
            for guess in ["private-value", "other"] {
                #expect(ScreenExpectation.element(label: "Field", expect: .value(guess))
                    .judge(windows: nil, scene: scene).verdict == .unknown)
            }
        }
    }
}
