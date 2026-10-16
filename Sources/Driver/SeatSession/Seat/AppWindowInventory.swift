//
//  AppWindowInventory.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics
import SeatCore

/// AppWindowChange is what one pass over the windows of the driven applications
/// found, said in the terms the seat acts on. There is no `moved` case on
/// purpose: a window the person already had on their own display is theirs
/// whether it stands still or not, and moving it because it moved is the
/// retroactive transfer this feature must not do.
nonisolated enum AppWindowChange: Equatable {

    /// A window of a driven process the seat does not hold, outside the Virtual
    /// Display, seen twice at the same frame. It was not there when the seat
    /// took control.
    case appeared(WindowReference)

    /// The same, for a window that had been seen, went out of the on-screen
    /// list, and came back.
    case reappeared(WindowReference)

    /// A window of a driven process the seat does not hold, seen twice at the
    /// same frame **inside** the Virtual Display, that was not there when the
    /// seat took control.
    ///
    /// It is its own case because it answers a different question from
    /// `appeared`: macOS opens a new window where the application's active
    /// window is, so a window opened while the agent works in the seat is born
    /// inside it. It needs no move, and it still needs an owner, because a
    /// window nobody adopted is a held member no release loop iterates and the
    /// handback refuses for it. One case rather than an `appeared` carrying a
    /// flag, so that the caller cannot spend a transfer attempt on a window
    /// that needs no transfer.
    case appearedInVirtualDisplay(WindowReference)

    /// A window the seat holds whose frame is no longer inside the Virtual
    /// Display.
    case leftVirtualDisplay(WindowReference)

    /// A window the seat holds that this reading no longer carries. One missing
    /// reading is not a destruction: it is the wake-up for whoever owns that
    /// proof.
    case vanished(windowNumber: Int)
}

/// AppWindowInventory is the pure half of following an application's windows:
/// what was there at the start, what is there now, and which of the differences
/// is worth acting on.
///
/// ## The first reading is a baseline and never a transfer
///
/// Everything the first reading of a process sees becomes the inventory and
/// produces nothing. That holds once per driving episode of a process, not at
/// every call (see `baseline`).
/// The windows an application already had on the person's displays when the
/// seat took control are the person's, and a feature that hoovered them onto
/// the Virtual Display because it had just started looking would be taking
/// windows nobody offered it.
///
/// ## Two agreeing readings before a candidate is one
///
/// A window is published to the window server before it has settled its
/// geometry, and `kAXWindowCreatedNotification` was measured arriving 79 to
/// 249 ms *before* the window server shows the window at all. So a frame read
/// at the first sighting is a frame that is about to change, and acting on it
/// centres a window by a size it does not have. A surface therefore becomes a
/// candidate only when a second reading carries the same identity at the same
/// frame, which is the same rule `confirmPlacement` uses at the other end of
/// the transaction.
///
/// The rule holds for every change this type emits, a window the seat already
/// holds included. A stale frame is not only a new window's problem: a Qt
/// target was measured publishing (4032, 2390, 1345, 949) for a window whose
/// own body read (1472, 1012, 1345, 949), and a frame like that is outside the
/// display. Acting on one reading there would report an escape that never
/// happened, spend an attempt on it, and eventually stop answering a real one.
///
/// ## Identity, never the Window ID alone
///
/// A record is keyed by Window ID and validated by `WindowIdentity`, so a
/// Window ID reused by another window reads as one window leaving and a
/// different one arriving instead of as the same window moving. Process
/// membership is compared on `ProcessIdentity`, so a PID reused after the
/// application terminated owns nothing the seat was driving.
///
/// It takes no reading and makes no system call: every reading is passed in,
/// which is why the whole of it is a unit test with no display attached. A
/// `nil` reading is `unknown` and changes nothing at all, because an empty list
/// answered for a failed read is how every window of an application reads as
/// destroyed at once.
nonisolated struct AppWindowInventory {

    /// How many times the seat may try to bring one Window ID under control
    /// before it stops. An application that puts its window back on the
    /// physical display after every move is an application that disagrees, and
    /// the third disagreement is the answer rather than a loop.
    static let maximumAttempts = 3

    private struct KnownSurface {

        let identity: WindowIdentity
        var frame   : CGRect

        /// A second reading has carried this identity at this frame, so the
        /// geometry has settled and the surface may be acted on.
        var agreed: Bool

        /// The last reading did not carry it. Kept rather than deleted: the
        /// record is what tells a window coming back from a window that was
        /// never there.
        var isMissing: Bool

        /// It has been missing at least once, which is what separates a
        /// reappearance from a first appearance.
        var hasReturned: Bool
    }

    private var known    : [Int: KnownSurface] = [:]
    private var attempts : [Int: Int]          = [:]

    /// The processes whose "already there" has been taken, for as long as the
    /// seat keeps driving them.
    private var baselined: Set<ProcessIdentity> = []

    /// True once the baseline pass has run. Before it, every difference is a
    /// window that was already there.
    private(set) var isPrimed = false

    /// True while a surface is waiting for the second reading that agrees with
    /// it, which is what tells the caller another pass soon is worth its cost.
    private(set) var hasPendingCandidate = false

    /// Takes the baseline of the processes that were not driven before, and
    /// forgets the processes that no longer are. It answers nothing.
    ///
    /// "Already there" is defined once per process and per driving episode: at
    /// the moment the seat first holds a window of that process. A process
    /// already baselined is left alone, however many times this is called, so a
    /// window the application opens while another adoption or release is
    /// finishing is still a candidate afterwards. Baselining every driven
    /// process at every call, which this used to do, turned any window born
    /// between a pass's reading and the end of someone else's transaction into
    /// furniture for good: a panel born 47 ms before an adoption ended was
    /// never adopted (Photoshop, Place Embedded).
    ///
    /// A process that is no longer in `processes` is forgotten with its
    /// surfaces and attempts, here and in `changes`, so driving it again takes
    /// a fresh baseline. Keeping the old
    /// records would propose every window the person opened meanwhile, which is
    /// the retroactive transfer this feature must not do. The key is
    /// `ProcessIdentity`, so a restarted application starts over as well.
    ///
    /// The limit is the first adoption of a process: the baseline is taken when
    /// the seat holds its first window, so a window the application opens
    /// between the start of that adoption and its end is read as already
    /// there. Taking it earlier is a different design, because nothing before
    /// the adoption knows which process will be driven.
    ///
    /// The reading is lazy and taken only when a process is new. A failed
    /// reading leaves the process unbaselined, and whichever succeeds first,
    /// the next call here or the next pass (`changes`), takes its baseline.
    /// Surfaces already known are left exactly as they are.
    mutating func baseline(
        surfaces : @autoclosure () -> [WindowSurface]?,
        processes: Set<ProcessIdentity>
    ) {
        forgetProcesses(otherThan: processes)
        guard !processes.isEmpty else { return }

        isPrimed = true
        let fresh = processes.subtracting(baselined)
        guard !fresh.isEmpty, let surfaces = surfaces() else { return }
        baselined.formUnion(fresh)

        for surface in surfaces {
            guard let identity = surface.reference.identity,
                  fresh.contains(identity.process),
                  known[identity.windowNumber] == nil
            else { continue }

            known[identity.windowNumber] = KnownSurface(
                identity   : identity,
                frame      : surface.reference.frame,
                agreed     : true,
                isMissing  : false,
                hasReturned: false
            )
        }
    }

    /// Records a reading the seat took while it could not act on it, so a
    /// window that appears meanwhile is a candidate the moment the seat can.
    ///
    /// It only notes sightings: a surface it does not know becomes a candidate
    /// waiting for its agreeing reading, and a candidate already waiting takes
    /// the frame of this one. It never reports a change, never touches a
    /// window the seat holds and never ends a candidacy, so a reading taken in
    /// the middle of an adoption cannot lose a vanish or an escape the pass
    /// has not yet reported. The first pass after the seat is free then finds
    /// the candidate at the same frame and reports it at once, instead of
    /// spending two more passes to see what an earlier one already saw.
    mutating func sight(
        surfaces : [WindowSurface]?,
        processes: Set<ProcessIdentity>,
        adopted  : Set<Int>
    ) {
        guard isPrimed, let surfaces else { return }

        for surface in surfaces {
            guard let identity = surface.reference.identity,
                  processes.contains(identity.process),
                  baselined.contains(identity.process),
                  !adopted.contains(identity.windowNumber)
            else { continue }

            if var record = known[identity.windowNumber], record.identity == identity {
                guard !record.agreed else { continue }
                record.frame = surface.reference.frame
                known[identity.windowNumber] = record
            } else {
                known[identity.windowNumber] = KnownSurface(
                    identity   : identity,
                    frame      : surface.reference.frame,
                    agreed     : false,
                    isMissing  : false,
                    hasReturned: false
                )
            }
            hasPendingCandidate = true
        }
    }

    /// Folds one reading in and answers what changed.
    ///
    /// `surfaces` is `nil` for a reading that failed, which leaves the whole
    /// inventory untouched. `adopted` is the Window IDs the seat holds, and a
    /// held window is judged by where it is rather than by whether it is new.
    /// `menuLevel` is the pop up menu level: a contextual menu has exactly one
    /// owner in this kit and it is not this one.
    mutating func changes(
        surfaces            : [WindowSurface]?,
        processes           : Set<ProcessIdentity>,
        adopted             : Set<Int>,
        within virtualBounds: CGRect,
        menuLevel           : Int
    ) -> [AppWindowChange] {

        guard let surfaces else { return [] }
        // The driven set is the truth whoever let a process go, so a process
        // dropped without a baseline call is still baselined afresh.
        forgetProcesses(otherThan: processes)

        var changes: [AppWindowChange] = []
        var seen   : Set<Int>          = []
        var pending                    = false

        for surface in surfaces {
            guard let identity = surface.reference.identity,
                  processes.contains(identity.process)
            else { continue }

            let windowNumber = identity.windowNumber
            seen.insert(windowNumber)

            guard let previous = known[windowNumber], previous.identity == identity else {
                // Never seen, or a different window behind a Window ID the
                // server handed out again. The baseline agrees with itself, and
                // so does the first reading of a process whose baseline failed.
                let isCandidate = baselined.contains(identity.process)
                known[windowNumber] = KnownSurface(
                    identity   : identity,
                    frame      : surface.reference.frame,
                    agreed     : !isCandidate,
                    isMissing  : false,
                    hasReturned: false
                )
                if isCandidate { pending = true }
                continue
            }

            var record     = previous
            let wasMissing = record.isMissing
            let sameFrame  = VirtualWindowPlacementCheck.framesMatch(
                record.frame,
                surface.reference.frame
            )
            record.isMissing = false
            record.frame     = surface.reference.frame
            if wasMissing {
                record.hasReturned = true
                record.agreed      = false
            }

            if adopted.contains(windowNumber) {
                // A window the seat holds is judged by the same two agreeing
                // readings as any other surface, and for a sharper reason: a
                // window server frame can be stale, measured on a Qt target as
                // (4032, 2390, 1345, 949) while the window's own body read
                // (1472, 1012, 1345, 949). A frame like that is outside the
                // display, so one reading would report an escape that never
                // happened and spend an attempt on it.
                let hasAgreed = sameFrame && !wasMissing
                record.agreed       = hasAgreed
                known[windowNumber] = record

                guard !virtualBounds.contains(surface.reference.frame) else {
                    // Back under control, so a later escape starts from a full
                    // budget rather than from what this one cost.
                    if hasAgreed { attempts[windowNumber] = nil }
                    continue
                }
                if hasAgreed { changes.append(.leftVirtualDisplay(surface.reference)) }
                else         { pending = true }
                continue
            }

            guard !record.agreed else {
                known[windowNumber] = record
                continue
            }

            guard sameFrame, !wasMissing else {
                known[windowNumber] = record
                pending = true
                continue
            }

            record.agreed       = isTransferable(surface, menuLevel: menuLevel)
            known[windowNumber] = record

            guard isPrimed, isTransferable(surface, menuLevel: menuLevel) else { continue }

            guard !virtualBounds.contains(surface.reference.frame) else {
                // Inside already, so nothing to move and still something to
                // own. A return and a reappearance are the same act here.
                changes.append(.appearedInVirtualDisplay(surface.reference))
                continue
            }

            changes.append(
                record.hasReturned ? .reappeared(surface.reference)
                                   : .appeared(surface.reference)
            )
        }

        for (windowNumber, previous) in known where !seen.contains(windowNumber) {
            guard !previous.isMissing else { continue }
            var record          = previous
            record.isMissing    = true
            record.agreed       = false
            known[windowNumber] = record
            if adopted.contains(windowNumber) {
                changes.append(.vanished(windowNumber: windowNumber))
            }
        }

        hasPendingCandidate = pending && isPrimed
        isPrimed            = true
        baselined.formUnion(processes)
        return changes
    }

    /// Forgets the baseline, the surfaces and the attempts of every process not
    /// in `processes`, so driving one of them again starts a new episode.
    private mutating func forgetProcesses(otherThan processes: Set<ProcessIdentity>) {
        baselined.formIntersection(processes)
        for (windowNumber, record) in known where !processes.contains(record.identity.process) {
            known[windowNumber]    = nil
            attempts[windowNumber] = nil
        }
    }

    /// Whether the seat may spend one more attempt on this Window ID, counting
    /// the attempt when it may. It answers false forever after the budget is
    /// spent, which is the bounded end of an application that keeps putting its
    /// own window back.
    mutating func mayAttempt(_ windowNumber: Int) -> Bool {
        let spent = attempts[windowNumber, default: 0]
        guard spent < Self.maximumAttempts else { return false }
        attempts[windowNumber] = spent + 1
        return true
    }

    /// Offers a window again on the next pass, without spending anything.
    ///
    /// A candidate is reported once, when two readings first agree on it, and
    /// never again while it stays where it is. That is right for a window the
    /// seat decided about, and wrong for one it **postponed**: MW-03 leaves a
    /// fullscreen window alone while its Space is the one on screen, and
    /// without this the window would be dropped for good a moment before it
    /// became movable.
    mutating func offerAgain(_ windowNumber: Int) {
        known[windowNumber]?.agreed = false
    }

    /// Forgets what was spent on a window that is now under control, so a
    /// window that leaves the display again later starts from a full budget
    /// rather than from the attempts its first transfer cost.
    mutating func clearAttempts(of windowNumber: Int) {
        attempts[windowNumber] = nil
    }

    /// A surface worth moving: visible, with an area, and drawn below the menu
    /// level. A menu is a temporary surface running a modal tracking loop inside
    /// somebody else's process and `useContextMenu` owns it whole; a second
    /// owner deciding to move one is how the tracking loop loses the window it
    /// was drawn for.
    ///
    /// What is drawn above menus is as transient: help tags, drag images and
    /// screen-saver level surfaces. Qt draws its drag image at level 1000 at the
    /// real cursor, on the person's screen, and moving it failed a seat.
    private func isTransferable(_ surface: WindowSurface, menuLevel: Int) -> Bool {
        (surface.isVisible || surface.isOnInactiveSpace) && surface.level < menuLevel
            && surface.reference.frame.width > 0 && surface.reference.frame.height > 0
    }
}
