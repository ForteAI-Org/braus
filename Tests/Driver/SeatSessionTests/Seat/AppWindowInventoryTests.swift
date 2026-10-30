//
//  AppWindowInventoryTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The diffing half of following an application's windows, with nothing
/// attached: no display, no window server, no accessibility grant. Every
/// reading is handed in, which is the point of the type being a value.
@Suite("The window inventory")
struct AppWindowInventoryTests {

    static let menuLevel = 101

    static let physical = CGRect(x: 100, y: 100, width: 800, height: 600)
    static let virtual  = FakeGeometry.virtual

    static var driven: Set<ProcessIdentity> {
        [FakeGeometry.identity().process]
    }

    static func surface(
        _ windowNumber: Int,
        frame         : CGRect = physical,
        level         : Int    = 0,
        isVisible     : Bool   = true,
        lifetime      : UInt32 = 1,
        processID     : Int32  = FakeGeometry.targetPID
    ) -> WindowSurface {
        WindowSurface(
            reference: FakeGeometry.reference(
                frame       : frame,
                processID   : processID,
                windowNumber: windowNumber,
                lifetime    : lifetime
            ),
            level    : level,
            isVisible: isVisible
        )
    }

    /// Folds readings in one after another and answers the last batch of
    /// changes, which is what every row here asserts on.
    @discardableResult
    static func fold(
        _ inventory: inout AppWindowInventory,
        _ readings : [[WindowSurface]?],
        adopted    : Set<Int> = [],
        processes  : Set<ProcessIdentity>? = nil
    ) -> [AppWindowChange] {
        var last: [AppWindowChange] = []
        for reading in readings {
            last = inventory.changes(
                surfaces : reading,
                processes: processes ?? driven,
                adopted  : adopted,
                within   : virtual,
                menuLevel: menuLevel
            )
        }
        return last
    }

    // MARK: The baseline

    @Test("a known inactive desktop supplies a transfer candidate after two agreeing readings")
    func inactiveDesktopCanTransfer() {
        var inventory = AppWindowInventory()
        inventory.baseline(surfaces: [Self.surface(700)], processes: Self.driven)
        let ordinary = Self.surface(701)
        let inactive = WindowSurface(reference: ordinary.reference, level: ordinary.level,
                                     isVisible: false, isOnInactiveSpace: true)
        #expect(Self.fold(&inventory, [[inactive]]).isEmpty)
        #expect(Self.fold(&inventory, [[inactive]]) == [.appeared(ordinary.reference)])
        #expect(Self.fold(&inventory, [[inactive]]).isEmpty)
    }

    @Test("an ineligible row does not consume its later appearance")
    func hiddenCandidateCanBecomeVisible() {
        var inventory = AppWindowInventory()
        inventory.baseline(surfaces: [Self.surface(700)], processes: Self.driven)
        let hidden = Self.surface(701, isVisible: false)
        #expect(Self.fold(&inventory, [[hidden], [hidden]]).isEmpty)
        let visible = Self.surface(701)
        #expect(Self.fold(&inventory, [[visible]]) == [.appeared(visible.reference)])
    }

    @Test("the first reading is a baseline and transfers nothing")
    func firstReadingIsABaseline() {
        var inventory = AppWindowInventory()
        let there     = [Self.surface(700), Self.surface(701)]

        #expect(Self.fold(&inventory, [there]).isEmpty)
        #expect(Self.fold(&inventory, [there]).isEmpty, "and it stays a baseline one pass later")
        #expect(inventory.isPrimed)
    }

    @Test("the baseline is taken when the seat starts driving, never at the first pass")
    func theBaselineIsTakenOnDemand() {
        var inventory = AppWindowInventory()
        let there     = [Self.surface(700), Self.surface(701)]
        inventory.baseline(surfaces: there, processes: Self.driven)

        #expect(inventory.isPrimed)
        #expect(Self.fold(&inventory, [there, there]).isEmpty)

        // A window that arrived after the baseline is a candidate, and a second
        // baseline does not quietly turn it into furniture.
        let arriving = Self.surface(702)
        let seenOnce = [Self.surface(700), arriving]
        #expect(Self.fold(&inventory, [seenOnce]).isEmpty)
        inventory.baseline(surfaces: seenOnce, processes: Self.driven)
        #expect(Self.fold(&inventory, [seenOnce]) == [.appeared(arriving.reference)])
    }

    @Test("a window born between one baseline and the next is still a candidate")
    func aWindowBornBetweenTwoBaselinesIsACandidate() {
        var inventory = AppWindowInventory()
        let there     = [Self.surface(700)]
        inventory.baseline(surfaces: there, processes: Self.driven)
        Self.fold(&inventory, [there])

        // Another adoption ends and the baseline is taken again, with a window
        // the pass has not read yet: it was never "already there".
        let born = Self.surface(702)
        inventory.baseline(surfaces: there + [born], processes: Self.driven)

        #expect(Self.fold(&inventory, [there + [born], there + [born]]) == [.appeared(born.reference)])
    }

    @Test("a process the seat no longer drives is forgotten, and driving it again takes a fresh baseline")
    func aForgottenProcessIsBaselinedAgain() {
        var inventory = AppWindowInventory()
        let there     = [Self.surface(700)]
        inventory.baseline(surfaces: there, processes: Self.driven)

        // A window the person opened is seen once, then every window is released.
        let opened = Self.surface(702)
        Self.fold(&inventory, [there + [opened]])
        inventory.baseline(surfaces: there + [opened], processes: [])

        // Driven again: what the person opened meanwhile is theirs, and moving
        // it would be a retroactive transfer.
        inventory.baseline(surfaces: there + [opened], processes: Self.driven)
        let first  = Self.fold(&inventory, [there + [opened]])
        let second = Self.fold(&inventory, [there + [opened]])
        #expect(first.isEmpty && second.isEmpty, "proposed: \(first + second)")
    }

    @Test("a process that joins is baselined without baselining the ones already driven")
    func aJoiningProcessIsBaselinedAlone() {
        var inventory = AppWindowInventory()
        let other     = FakeGeometry.distinctProcessID()
        let both      = Self.driven.union([FakeGeometry.identity(processID: other).process])

        inventory.baseline(surfaces: [Self.surface(700)], processes: Self.driven)
        let born  = Self.surface(702)
        let there = Self.surface(710, processID: other)
        inventory.baseline(surfaces: [Self.surface(700), born, there], processes: both)

        let reading = [Self.surface(700), born, there]
        #expect(Self.fold(&inventory, [reading, reading], processes: both) == [.appeared(born.reference)])
    }

    @Test("the window server is read only when a process is new")
    func theBaselineReadingIsLazy() {
        var inventory = AppWindowInventory()
        var readings  = 0
        func read() -> [WindowSurface] { readings += 1; return [Self.surface(700)] }

        inventory.baseline(surfaces: read(), processes: Self.driven)
        inventory.baseline(surfaces: read(), processes: Self.driven)
        inventory.baseline(surfaces: read(), processes: [])
        #expect(readings == 1)

        inventory.baseline(surfaces: read(), processes: Self.driven)
        #expect(readings == 2, "a process driven again is new again")
    }

    @Test("a process the passes stop reading is forgotten even without a baseline call")
    func aProcessDroppedBetweenBaselinesIsForgotten() {
        var inventory = AppWindowInventory()
        let other     = FakeGeometry.distinctProcessID()
        let first     = FakeGeometry.identity().process
        let second    = FakeGeometry.identity(processID: other).process
        let held      = Self.surface(700)
        let otherHeld = Self.surface(710, processID: other)
        inventory.baseline(surfaces: [held, otherHeld], processes: [first, second])
        Self.fold(&inventory, [[held, otherHeld]], adopted: [700, 710], processes: [first, second])

        // The first process's only window is gone and the passes read the second
        // alone; then the person opens a window of the first, which is driven again.
        Self.fold(&inventory, [[otherHeld], [otherHeld]], adopted: [710], processes: [second])
        let persons = Self.surface(705)
        let again   = Self.surface(706)
        let reading = [persons, again, otherHeld]
        inventory.baseline(surfaces: reading, processes: [first, second])

        let proposed = Self.fold(&inventory, [reading, reading], adopted: [706, 710], processes: [first, second])
        #expect(!proposed.contains(.appeared(persons.reference)), "retroactive: \(proposed)")
    }

    @Test("a forgotten process leaves its attempts behind")
    func aForgottenProcessForgetsItsAttempts() {
        var inventory = AppWindowInventory()
        let window    = [Self.surface(700)]
        inventory.baseline(surfaces: window, processes: Self.driven)
        for _ in 0..<AppWindowInventory.maximumAttempts { _ = inventory.mayAttempt(700) }
        let spent = inventory.mayAttempt(700)
        #expect(!spent)

        inventory.baseline(surfaces: window, processes: [])
        let renewed = inventory.mayAttempt(700)
        #expect(renewed, "driving it again starts from a full budget")
    }

    @Test("a failed baseline reading leaves the process to be baselined at the next call")
    func aFailedBaselineIsRetried() {
        var inventory = AppWindowInventory()
        inventory.baseline(surfaces: nil, processes: Self.driven)
        inventory.baseline(surfaces: [Self.surface(700)], processes: Self.driven)

        let first  = Self.fold(&inventory, [[Self.surface(700)]])
        let second = Self.fold(&inventory, [[Self.surface(700)]])
        #expect(first.isEmpty && second.isEmpty, "proposed: \(first + second)")
    }

    @Test("a failed baseline reading is taken by the next pass, which proposes nothing")
    func aFailedBaselineIsTakenByThePass() {
        var inventory = AppWindowInventory()
        let there     = [Self.surface(700)]
        inventory.baseline(surfaces: nil, processes: Self.driven)

        // A sighting before any reading succeeded has no baseline to compare with.
        inventory.sight(surfaces: there, processes: Self.driven, adopted: [])
        let first  = Self.fold(&inventory, [there])
        let second = Self.fold(&inventory, [there])
        #expect(first.isEmpty && second.isEmpty, "the person's window was proposed: \(first + second)")
    }

    @Test("a process baselined by a pass is not baselined again by the next call")
    func aPassBaselineHoldsAcrossTheNextCall() {
        var inventory = AppWindowInventory()
        let there     = [Self.surface(700)]
        inventory.baseline(surfaces: nil, processes: Self.driven)
        Self.fold(&inventory, [there])

        let born = Self.surface(702)
        inventory.baseline(surfaces: there + [born], processes: Self.driven)
        #expect(Self.fold(&inventory, [there + [born], there + [born]]) == [.appeared(born.reference)])
    }

    @Test("a sighting taken while the seat cannot act is proposed by the first pass after it")
    func aSightingIsProposedAtOnce() {
        var inventory = AppWindowInventory()
        let there     = [Self.surface(700)]
        inventory.baseline(surfaces: there, processes: Self.driven)

        let born = Self.surface(702)
        inventory.sight(surfaces: there + [born], processes: Self.driven, adopted: [])
        #expect(inventory.hasPendingCandidate)
        #expect(Self.fold(&inventory, [there + [born]]) == [.appeared(born.reference)],
                "one pass, not the two a fresh sighting costs")
    }

    @Test("a sighting never reports, never touches a held window and never loses a vanish")
    func aSightingChangesNothingElse() {
        var inventory = AppWindowInventory()
        let held      = Self.surface(700)
        inventory.baseline(surfaces: [held], processes: Self.driven)
        Self.fold(&inventory, [[held]], adopted: [700])

        inventory.sight(surfaces: [], processes: Self.driven, adopted: [700])
        inventory.sight(surfaces: nil, processes: Self.driven, adopted: [700])
        #expect(Self.fold(&inventory, [[]], adopted: [700]) == [.vanished(windowNumber: 700)])
    }

    @Test("a window already on the person's display that moves is still not transferred")
    func aPreexistingWindowThatMovesStaysPut() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let moved = Self.surface(700, frame: Self.physical.offsetBy(dx: 300, dy: 40))
        #expect(Self.fold(&inventory, [[moved], [moved]]).isEmpty)
    }

    // MARK: A window that arrives

    @Test("a new window is a candidate only once two readings agree on it")
    func newWindowNeedsTwoAgreeingReadings() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let arriving = Self.surface(701)
        #expect(Self.fold(&inventory, [[Self.surface(700), arriving]]).isEmpty,
                "one reading of a window whose geometry has not settled is not evidence")
        #expect(inventory.hasPendingCandidate)

        let changes = Self.fold(&inventory, [[Self.surface(700), arriving]])
        #expect(changes == [.appeared(arriving.reference)])
        #expect(!inventory.hasPendingCandidate)
    }

    @Test("a window whose frame is still moving is not acted on")
    func aWindowStillSettlingIsNotACandidate() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let first  = Self.surface(701, frame: CGRect(x: 100, y: 100, width: 10, height: 10))
        let second = Self.surface(701, frame: Self.physical)
        #expect(Self.fold(&inventory, [[first], [second]]).isEmpty)
        #expect(inventory.hasPendingCandidate)
        #expect(Self.fold(&inventory, [[second]]) == [.appeared(second.reference)])
    }

    @Test("a window that went away and came back is a reappearance and not a new window")
    func aWindowThatComesBack() {
        var inventory = AppWindowInventory()
        let window    = Self.surface(701)
        Self.fold(&inventory, [[Self.surface(700), window]])

        // Out of the on-screen list, then back at the same frame.
        Self.fold(&inventory, [[Self.surface(700)]])
        let changes = Self.fold(&inventory, [
            [Self.surface(700), window],
            [Self.surface(700), window],
        ])
        #expect(changes == [.reappeared(window.reference)])
    }

    @Test("two windows arriving in the same reading are both answered")
    func simultaneousArrivals() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let a = Self.surface(701)
        let b = Self.surface(702, frame: Self.physical.offsetBy(dx: 40, dy: 40))
        let changes = Self.fold(&inventory, [[a, b], [a, b]])
        #expect(Set(changes.map(Self.windowNumber)) == [701, 702])
    }

    // MARK: What is never a candidate

    @Test("a contextual menu, an invisible surface and another application are all left alone")
    func surfacesThatAreNotCandidates() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let menu      = Self.surface(701, level: Self.menuLevel)
        let invisible = Self.surface(702, isVisible: false)
        let stranger  = Self.surface(703, processID: FakeGeometry.userPID)
        let reading   = [Self.surface(700), menu, invisible, stranger]

        #expect(Self.fold(&inventory, [reading, reading]).isEmpty)
    }

    @Test("a PID reused after the application terminated inherits nothing")
    func aReusedProcessIDInheritsNothing() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        // Same PID, a different process lifetime: another application that
        // happened to be handed the number the driven one left behind.
        let successor = Self.surface(701, lifetime: 9)
        #expect(Self.fold(&inventory, [[successor], [successor]]).isEmpty)
    }

    @Test("a contextual menu that opens inside the virtual display is still left alone")
    func aMenuInsideTheDisplayIsNotACandidate() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        // The one surface that opens inside the seat by design: `useContextMenu`
        // owns it whole and a second owner adopting it loses the tracking loop.
        let menu    = Self.surface(701, frame: FakeGeometry.adoptedWindow.frame, level: Self.menuLevel)
        let reading = [Self.surface(700), menu]

        #expect(Self.fold(&inventory, [reading, reading]).isEmpty)
    }

    @Test("a window already inside the virtual display at the baseline is still never taken")
    func aBaselinedWindowInsideTheDisplayIsNeverTaken() {
        var inventory = AppWindowInventory()
        let inside    = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        inventory.baseline(surfaces: [inside], processes: Self.driven)

        #expect(Self.fold(&inventory, [[inside], [inside]]).isEmpty,
                "everything present when the seat took control is the person's")
    }

    // MARK: A window born inside the seat

    @Test("a window that appears inside the virtual display is offered for ownership, not for a move")
    func aWindowBornInsideTheDisplay() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        // Where macOS puts a new window: next to the application's active one,
        // which is the window the agent is working in, inside the seat.
        let inside  = Self.surface(701, frame: FakeGeometry.adoptedWindow.frame)
        let reading = [Self.surface(700), inside]

        #expect(Self.fold(&inventory, [reading]).isEmpty, "one reading is still a sighting")
        #expect(inventory.hasPendingCandidate)
        #expect(Self.fold(&inventory, [reading]) == [.appearedInVirtualDisplay(inside.reference)])

        // Nothing was moved, so the whole budget is still there for the day the
        // window does leave the display.
        for attempt in 1...AppWindowInventory.maximumAttempts {
            let allowed = inventory.mayAttempt(701)
            #expect(allowed, "attempt \(attempt) was spent on a window that needed no transfer")
        }
    }

    @Test("a window that appears outside the virtual display is still a transfer")
    func aWindowBornOutsideIsStillATransfer() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        let outside = Self.surface(701, frame: Self.physical.offsetBy(dx: 20, dy: 20))
        let reading = [Self.surface(700), outside]
        #expect(Self.fold(&inventory, [reading, reading]) == [.appeared(outside.reference)])
    }

    @Test("an announced window born outside the virtual display is a transfer at its first reading")
    func anAnnouncedWindowOutsideIsTakenAtOnce() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        inventory.announce(701)
        let animating = Self.surface(701, frame: Self.physical.insetBy(dx: 4, dy: 1))
        #expect(Self.fold(&inventory, [[Self.surface(700), animating]]) == [.appeared(animating.reference)])
        #expect(!inventory.hasPendingCandidate)
        #expect(Self.fold(&inventory, [[Self.surface(700), Self.surface(701)]]).isEmpty,
                "the announcement is spent: the settled frame is not offered a second time")
    }

    @Test("an announcement changes nothing inside the virtual display, nor for a window never announced")
    func anAnnouncementKeepsTheOtherRules() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        inventory.announce(701)
        let inside = Self.surface(701, frame: FakeGeometry.adoptedWindow.frame)
        let silent = Self.surface(702, frame: Self.physical.offsetBy(dx: 20, dy: 20))
        let reading = [Self.surface(700), inside, silent]
        #expect(Self.fold(&inventory, [reading]).isEmpty)
        #expect(Self.fold(&inventory, [reading]) == [
            .appearedInVirtualDisplay(inside.reference),
            .appeared(silent.reference),
        ])
    }

    @Test("an announced window first sighted during an adoption is taken by the next pass even if it moved")
    func anAnnouncedSightingIsTakenWhileStillAnimating() {
        var inventory = AppWindowInventory()
        Self.fold(&inventory, [[Self.surface(700)]])

        inventory.announce(701)
        let first  = Self.surface(701, frame: Self.physical.insetBy(dx: 4, dy: 1))
        let second = Self.surface(701, frame: Self.physical)
        inventory.sight(surfaces: [Self.surface(700), first], processes: Self.driven, adopted: [])
        #expect(Self.fold(&inventory, [[Self.surface(700), second]]) == [.appeared(second.reference)])
    }

    @Test("a window the seat already holds is judged by where it is, never offered again")
    func aHeldWindowInsideIsNotOfferedAgain() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)

        #expect(Self.fold(&inventory, [[home], [home], [home]], adopted: [700]).isEmpty)
    }

    // MARK: The windows the seat holds

    @Test("a held window that leaves the display is reported once two readings agree")
    func heldWindowThatLeaves() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        Self.fold(&inventory, [[home]], adopted: [700])
        #expect(Self.fold(&inventory, [[home]], adopted: [700]).isEmpty)

        // The same rule as every other surface: one reading is a sighting.
        let left = Self.surface(700)
        #expect(Self.fold(&inventory, [[left]], adopted: [700]).isEmpty)
        #expect(inventory.hasPendingCandidate, "and it is worth looking again soon")
        #expect(Self.fold(&inventory, [[left]], adopted: [700])
            == [.leftVirtualDisplay(left.reference)])
    }

    @Test("a single frame outside the display reports nothing and costs no attempt")
    func oneStaleFrameIsNotAnEscape() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        Self.fold(&inventory, [[home]], adopted: [700])

        // What a Qt target was measured publishing: one frame outside the
        // display, the next one back where the window really is.
        let stale = Self.surface(700, frame: CGRect(x: 4032, y: 2390, width: 1345, height: 949))
        #expect(Self.fold(&inventory, [[stale], [home]], adopted: [700]).isEmpty)

        for attempt in 1...AppWindowInventory.maximumAttempts {
            let allowed = inventory.mayAttempt(700)
            #expect(allowed, "attempt \(attempt) was spent on an escape that never happened")
        }
    }

    @Test("a held window that comes back under control gets its attempts back")
    func aReturnedWindowStartsFromAFullBudget() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        let left      = Self.surface(700)
        Self.fold(&inventory, [[home]], adopted: [700])
        Self.fold(&inventory, [[left], [left]], adopted: [700])

        for _ in 1...AppWindowInventory.maximumAttempts { _ = inventory.mayAttempt(700) }
        let exhausted = inventory.mayAttempt(700)
        #expect(!exhausted)

        // Two agreeing readings back inside the display, which is the window
        // under control again and not a guess about it.
        Self.fold(&inventory, [[home], [home]], adopted: [700])
        let afterReturn = inventory.mayAttempt(700)
        #expect(afterReturn, "a later escape has to be answerable")
    }

    @Test("a held window missing from the reading is reported once, not at every pass")
    func heldWindowThatVanishes() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        Self.fold(&inventory, [[home]], adopted: [700])

        #expect(Self.fold(&inventory, [[]], adopted: [700]) == [.vanished(windowNumber: 700)])
        #expect(Self.fold(&inventory, [[]], adopted: [700]).isEmpty)
    }

    @Test("a reading that failed changes nothing at all")
    func anUnknownReadingIsNotAnEmptyDesktop() {
        var inventory = AppWindowInventory()
        let home      = Self.surface(700, frame: FakeGeometry.adoptedWindow.frame)
        Self.fold(&inventory, [[home]], adopted: [700])

        let unknown: [WindowSurface]? = nil
        #expect(Self.fold(&inventory, [unknown], adopted: [700]).isEmpty,
                "an unreadable window server is unknown, never a desktop with nothing on it")

        // And the window is still known afterwards: the failed reading did not
        // forget it, so it is not a new window when the next reading succeeds.
        #expect(Self.fold(&inventory, [[home]], adopted: [700]).isEmpty)
    }

    // MARK: The attempt budget

    @Test("the attempts on one window are bounded and a transferred window starts again")
    func attemptsAreBounded() {
        var inventory = AppWindowInventory()
        for attempt in 1...AppWindowInventory.maximumAttempts {
            let allowed = inventory.mayAttempt(701)
            #expect(allowed, "attempt \(attempt) is inside the budget")
        }
        let exhausted = inventory.mayAttempt(701)
        #expect(!exhausted)

        let otherWindow = inventory.mayAttempt(702)
        #expect(otherWindow, "the budget is per window and not per seat")

        inventory.clearAttempts(of: 701)
        let afterTransfer = inventory.mayAttempt(701)
        #expect(afterTransfer)
    }

    private static func windowNumber(_ change: AppWindowChange) -> Int {
        switch change {
            case .appeared(let window), .reappeared(let window),
                 .appearedInVirtualDisplay(let window), .leftVirtualDisplay(let window):
                window.windowNumber
            case .vanished(let windowNumber):
                windowNumber
        }
    }
}
