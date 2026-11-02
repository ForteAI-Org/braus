import AppKit
import SeatCore
import Observation
import Synchronization
import SeatSession
import Testing
@testable import SeatBroker

@MainActor
@Suite("Held window presentation")
struct HeldWindowTests {
    @Test func classifiesAXRolesBeforeUsingLevel() {
        #expect(HeldWindow.Kind.classify(role: "AXSheet", subrole: nil, level: 0) == .sheet)
        #expect(HeldWindow.Kind.classify(role: "AXWindow", subrole: "AXDialog", level: 8) == .dialog)
        #expect(HeldWindow.Kind.classify(role: "AXWindow", subrole: "AXSystemDialog", level: 0) == .dialog)
        #expect(HeldWindow.Kind.classify(role: "AXWindow", subrole: "AXFloatingWindow", level: 3) == .panel)
        #expect(HeldWindow.Kind.classify(role: "AXDrawer", subrole: nil, level: 0) == .panel)
        #expect(HeldWindow.Kind.classify(role: "AXWindow", subrole: "AXStandardWindow", level: 0) == .main)
        #expect(HeldWindow.Kind.classify(role: nil, subrole: nil, level: 3) == .panel)
        #expect(HeldWindow.Kind.classify(role: nil, subrole: nil, level: 0) == .other)
        #expect(HeldWindow.Kind.classify(role: nil, subrole: nil, level: 101) == .other)
    }

    @Test func projectsAppearCloseResizeAndOrder() {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory)
        let process = ProcessIdentity(processID: 42, serialNumberHigh: 1, serialNumberLow: 2)
        func surface(_ number: Int, width: CGFloat = 800) -> WindowSurface {
            WindowSurface(reference: WindowReference(
                identity: WindowIdentity(process: process, windowNumber: number, ownerConnectionID: 3),
                frame: CGRect(x: 2000, y: 40, width: width, height: 500)), level: 0, isVisible: true)
        }
        session.updateHeldWindows([surface(1)], metadata: [:])
        #expect(session.heldWindows.map(\.windowNumber) == [1])
        let changed = Mutex(false)
        withObservationTracking {
            _ = session.heldWindows
        } onChange: {
            changed.withLock { $0 = true }
        }
        session.updateHeldWindows([surface(1)], metadata: [:])
        #expect(!changed.withLock { $0 })
        session.updateHeldWindows([surface(2), surface(1)], metadata: [:])
        #expect(session.heldWindows.map(\.windowNumber) == [2, 1])
        #expect(session.heldWindows.map(\.order) == [0, 1])
        session.updateHeldWindows([surface(1, width: 900), surface(2)], metadata: [:])
        #expect(session.heldWindows[0].frame.width == 900)
        #expect(session.heldWindows.map(\.windowNumber) == [1, 2])
        session.updateHeldWindows([surface(2)], metadata: [:])
        #expect(session.heldWindows.map(\.windowNumber) == [2])
        #expect(session.makeScreenView(contentsScale: 2) == nil)
        #expect(session.makeWindowView(windowNumber: 2, contentsScale: 2) == nil)
    }
}
