import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@MainActor
@Suite("Held window inventory")
struct HeldWindowInventoryTests {
    @Test func followsAppearanceClosureGeometryAndOrderWithoutAnotherPoller() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader = ControlledSurfaceReader(sensing: sensing)
        let (seat, adopted) = try await AppWindowFollowTests.followingSeat(
            sensing: sensing, placing: placing, reader: reader)
        var deliveries = 0
        seat.heldWindowsChanged = { deliveries += 1 }
        await seat.runWindowFollowPass()
        #expect(seat.heldWindowSurfaces.map(\.reference.windowNumber) == [adopted.id])

        let second = AppWindowFollowTests.reference(778, frame: CGRect(x: 1800, y: 100, width: 400, height: 300))
        sensing.additionalWindows[778] = second
        sensing.surfaces = [AppWindowFollowTests.surface(second), AppWindowFollowTests.surface(adopted.reference)]
        await seat.runWindowFollowPass()
        await seat.runWindowFollowPass()
        #expect(Set(seat.heldWindowSurfaces.map(\.reference.windowNumber)) == [adopted.id, 778])
        #expect(seat.heldWindowSurfaces.first?.reference.windowNumber == 778)

        let resized = second.replacingFrame(CGRect(x: 1900, y: 160, width: 450, height: 350))
        sensing.additionalWindows[778] = resized
        sensing.surfaces = [AppWindowFollowTests.surface(adopted.reference), AppWindowFollowTests.surface(resized)]
        await seat.runWindowFollowPass()
        #expect(seat.heldWindowSurfaces.map(\.reference.windowNumber) == [adopted.id, 778])
        #expect(seat.heldWindowSurfaces.last?.reference.frame == resized.frame)

        sensing.additionalWindows[778] = nil
        sensing.surfaces = [AppWindowFollowTests.surface(adopted.reference)]
        reader.destroyed = [try #require(second.identity)]
        await seat.runWindowFollowPass()
        #expect(seat.heldWindowSurfaces.map(\.reference.windowNumber) == [adopted.id])
        #expect(deliveries >= 4)
        seat.stopWindowFollowing()
    }
}
