//
//  SeatHolds.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/10/2026.
//

import Foundation
import Synchronization

/// SeatHolds is the application each seat session of this process holds, by bundle id, so a route that changes an app
/// behind the seat's back (an app adapter) can refuse while any session drives that app, not only the caller's.
///
/// A session records what it holds when it opens an application and forgets it when it closes. In memory only, for
/// this process: another process's seats are not seen.
nonisolated public enum SeatHolds {

    private static let held = Mutex<[UUID: String]>([:])

    /// Records `bundleID` as what the session `owner` holds, or forgets its hold when nil.
    public static func set(_ bundleID: String?, for owner: UUID) {
        held.withLock { $0[owner] = bundleID }
    }

    /// What the session `owner` holds now, nil when it holds nothing.
    public static func bundleID(heldBy owner: UUID) -> String? {
        held.withLock { $0[owner] }
    }

    /// The bundle ids some session holds now.
    public static var bundleIDs: Set<String> {
        held.withLock { Set($0.values) }
    }
}
