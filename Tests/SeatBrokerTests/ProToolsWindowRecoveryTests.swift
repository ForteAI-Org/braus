import ApplicationServices
import Testing
@testable import SeatBroker

@MainActor
@Suite("Pro Tools without a visible document")
struct ProToolsWindowRecoveryTests {
    typealias Item = ProToolsWindowRecovery.Item<Int>

    @Test("an open session reveals Edit; it never opens the Dashboard")
    func anOpenSessionRevealsEdit() throws {
        var pressed: [Int] = []
        let path = try ProToolsWindowRecovery.request(
            edit           : Item(element: 1, enabled: true),
            dashboard      : Item(element: 2, enabled: true),
            sessionOpen    : true,
            windowAvailable: { false },
            press          : { pressed.append($0); return .success }
        )
        #expect(path == "Window > Edit")
        #expect(pressed == [1])
    }

    @Test("without a session the Dashboard is pressed once, even when AX times out",
          arguments: [AXError.success, .cannotComplete])
    func aClosedSessionOpensDashboard(answer: AXError) throws {
        var pressed: [Int] = []
        let path = try ProToolsWindowRecovery.request(
            edit           : Item(element: 1, enabled: false),
            dashboard      : Item(element: 2, enabled: true),
            sessionOpen    : false,
            windowAvailable: { false },
            press          : { pressed.append($0); return answer }
        )
        #expect(path == "File > Dashboard...")
        #expect(pressed == [2])
    }

    @Test("an unreadable session state or a disabled destination presses nothing",
          arguments: [Optional<Bool>.none, true, false])
    func uncertainOrDisabledStateRefuses(sessionOpen: Bool?) {
        var pressed: [Int] = []
        #expect(throws: (any Error).self) {
            try ProToolsWindowRecovery.request(
                edit           : Item(element: 1, enabled: false),
                dashboard      : Item(element: 2, enabled: false),
                sessionOpen    : sessionOpen,
                windowAvailable: { false },
                press          : { pressed.append($0); return .success }
            )
        }
        #expect(pressed.isEmpty)
    }

    @Test("a window that appeared during the menu reading cancels the request")
    func aLateWindowPreventsThePress() throws {
        var pressed: [Int] = []
        let path = try ProToolsWindowRecovery.request(
            edit           : Item(element: 1, enabled: false),
            dashboard      : Item(element: 2, enabled: true),
            sessionOpen    : false,
            windowAvailable: { true },
            press          : { pressed.append($0); return .success }
        )
        #expect(path == nil)
        #expect(pressed.isEmpty)
    }

    @Test("an AX error retains one attempt and never tries the other window command")
    func aFailedPressIsNotReplayed() {
        var pressed: [Int] = []
        #expect(throws: (any Error).self) {
            try ProToolsWindowRecovery.request(
                edit           : Item(element: 1, enabled: true),
                dashboard      : Item(element: 2, enabled: true),
                sessionOpen    : true,
                windowAvailable: { false },
                press          : { pressed.append($0); return .failure }
            )
        }
        #expect(pressed == [1])
    }
}
