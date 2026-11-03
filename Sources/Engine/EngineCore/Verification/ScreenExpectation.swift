import Foundation
import PerceptionCore

/// ScreenExpectation names an observable screen result, retaining operands only in the call's RAM.
public enum ScreenExpectation: Sendable, Equatable {
    case window(title: String, open: Bool)
    case element(label: String, expect: ElementExpectation)

    @TaskLocal
    public static var current: ScreenExpectation?

    /// Composition supplies the same value visibility used for the model's scene.
    @TaskLocal
    public static var valueIsReadable: @Sendable (String) -> Bool = { _ in true }

    /// Compares the final reading using the same rules as the task result check.
    public func judge(windows: [String]?, scene: SceneSnapshot?) -> (verdict: OperationCheck.Verdict, observed: String) {
        func verdict(_ verdict: OperationCheck.Verdict, _ observed: String) -> (verdict: OperationCheck.Verdict, observed: String) {
            (verdict, observed)
        }
        switch self {
            case .window(let title, let open):
                guard let windows else {
                    return verdict(open ? .failed : .passed, OutcomeText.expectationApplicationAbsent)
                }
                let found = windows.contains { $0.localizedCaseInsensitiveContains(title) || LabelText.normalize($0).contains(LabelText.normalize(title)) }
                switch (open, found) {
                    case (true, true): return verdict(.passed, OutcomeText.expectationWindowOpen)
                    case (true, false): return verdict(.failed, OutcomeText.expectationWindowAbsent)
                    case (false, true): return verdict(.failed, OutcomeText.expectationWindowStillOpen)
                    case (false, false): return verdict(.passed, OutcomeText.expectationWindowAbsent)
                }
            case .element(let label, let expect):
                guard let scene else { return verdict(.unknown, OutcomeText.expectationSceneUnavailable) }
                let wanted = LabelText.normalize(label)
                let matching = scene.elements.filter { element in
                    !wanted.isEmpty && (LabelText.normalize(element.label) == wanted || element.id == label)
                }
                let fields = scene.outOfViewFields.filter {
                    !wanted.isEmpty && LabelText.normalize($0.label) == wanted
                }
                let found = !matching.isEmpty || !fields.isEmpty
                let location = matching.isEmpty && !fields.isEmpty ? OutcomeText.expectationOutsideWindow : ""
                switch expect {
                    case .present:
                        return found ? verdict(.passed, OutcomeText.expectationElementPresent + location)
                            : verdict(.failed, OutcomeText.expectationElementAbsent)
                    case .absent:
                        return found ? verdict(.failed, OutcomeText.expectationElementStillPresent + location)
                            : verdict(.passed, OutcomeText.expectationElementAbsent)
                    case .value(let value):
                        guard found else { return verdict(.failed, OutcomeText.expectationElementAbsent) }
                        guard !matching.contains(where: { $0.role == "AXSecureTextField" }),
                              !fields.contains(where: { $0.role == "AXSecureTextField" }) else {
                            return verdict(.unknown, OutcomeText.expectationValueUnreadable + location)
                        }
                        let read = matching.compactMap(\.value)
                        guard read.allSatisfy(Self.valueIsReadable), fields.allSatisfy({ Self.valueIsReadable($0.value) }) else {
                            return verdict(.unknown, OutcomeText.expectationValueUnreadable + location)
                        }
                        guard !read.isEmpty || !fields.isEmpty else {
                            return verdict(.unknown, OutcomeText.expectationValueUnreadable + location)
                        }
                        let expected = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        func same(_ shown: String) -> Bool {
                            let shown = shown.trimmingCharacters(in: .whitespacesAndNewlines)
                            return shown == expected || (!LabelText.normalize(expected).isEmpty
                                                         && LabelText.normalize(shown) == LabelText.normalize(expected))
                        }
                        if read.contains(where: same) { return verdict(.passed, OutcomeText.expectationValueExpected) }
                        if fields.contains(where: { same($0.value) }) {
                            return verdict(.passed, OutcomeText.expectationOutsideValueExpected)
                        }
                        return verdict(.failed, OutcomeText.expectationElement + location + OutcomeText.expectationValueDifferent)
                    case .state(let state):
                        guard found else { return verdict(.failed, OutcomeText.expectationElementAbsent) }
                        let read = matching.compactMap(\.state).filter { $0 != .unknown }
                        guard !read.isEmpty else {
                            return verdict(.unknown,
                                OutcomeText.expectationElement + location + OutcomeText.expectationStateUnreadable)
                        }
                        return read.contains(state) ? verdict(.passed, OutcomeText.expectationStateExpected)
                            : verdict(.failed, OutcomeText.expectationStateDifferent)
                }
        }
    }
}

/// ElementExpectation is the value, state or presence a readable element must show.
public enum ElementExpectation: Sendable, Equatable, Hashable {
    case value(String)
    case state(ControlState)
    case present
    case absent
}
