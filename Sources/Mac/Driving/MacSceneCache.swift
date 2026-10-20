import CoreGraphics
import Foundation
import MacDriver
import Synchronization

/// MacSceneCache keeps, per process, the last window `MacScenes` read: its tree, its index in
/// `AXWindows` and its window-server number. `MacActuator` resolves the engine's points against it,
/// because the engine acts on the scene it was just given, never on a newer one.
///
/// Entries are replaced by every read and never expire; an entry older than the live window is
/// caught at acting time (`staleTarget`).
public final class MacSceneCache: Sendable {

    public struct Entry: Sendable, Equatable {
        public var window: MacTreeNode
        public var windowIndex: Int
        /// The window server's number, 0 when no window of the process had the same frame.
        public var windowNumber: Int
        /// When the read started: the person's input after it makes the scene stale.
        public var readAt: ContinuousClock.Instant
        /// The window the tree was read from (`MacTreeRead.windowIdentity`), which every address made from this
        /// entry carries; nil when the reader gave none.
        public var windowIdentity: MacWindowIdentity?

        public init(
            window        : MacTreeNode,
            windowIndex   : Int,
            windowNumber  : Int,
            readAt        : ContinuousClock.Instant = .now,
            windowIdentity: MacWindowIdentity? = nil
        ) {
            self.window         = window
            self.windowIndex    = windowIndex
            self.windowNumber   = windowNumber
            self.readAt         = readAt
            self.windowIdentity = windowIdentity
        }
    }

    private let entries = Mutex<[pid_t: Entry]>([:])

    public init() {}

    public func store(_ entry: Entry, for processID: pid_t) {
        entries.withLock { $0[processID] = entry }
    }

    public func latest(for processID: pid_t) -> Entry? {
        entries.withLock { $0[processID] }
    }
}
