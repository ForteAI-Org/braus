//
//  HouseRoster.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation
import ModelTransports

/// HouseRoster reads the team's active workers as the house shows them, in the sidebar's order: the
/// real state of each worker becomes the light of its room (`status(...)`), its badge and its screen.
///
/// The app stores no status: a worker's light is derived each time from what the team knows. An
/// archived worker is never a room. A worker's shape is its own (`WorkerSnapshot.shape`), derived from
/// its id until the person picks one.
@MainActor
enum HouseRoster {

    /// The team's active workers as the house shows them. `showsUnreadCount` is the sidebar's setting
    /// (`AppPreferences.sidebarShowsUnreadCount`). A worker an adapter call waits on the person for
    /// (`TeamModel.awaitingApproval`) is waiting.
    static func workers(
        of team         : TeamModel,
        showsUnreadCount: Bool = true
    ) -> [HouseWorker] {
        let awaitingApproval = team.awaitingApproval
        return team.rows.map { row in
            worker(
                row,
                provider          : row.worker.configuration.flatMap { team.connections.states[$0.provider] },
                isAnswering       : team.isAnswering(row.id),
                usesScreen        : team.hasScreen(row.id),
                isAwaitingApproval: awaitingApproval.contains(row.id),
                showsUnreadCount  : showsUnreadCount
            )
        }
    }

    /// `row`'s worker as the house shows it. `provider` is what the last check of its provider found,
    /// nil before one. While it answers with nothing more precise to say, its activity is "Working";
    /// otherwise, with no activity, it is the worker's role, so the line under the name never reads empty.
    /// A worker with no model reads "Needs Setup" under its name, and VoiceOver reads it as its team row.
    nonisolated static func worker(
        _ row             : TeamRow,
        provider          : ConnectionState?,
        isAnswering       : Bool,
        usesScreen        : Bool,
        isAwaitingApproval: Bool = false,
        showsUnreadCount  : Bool = true
    ) -> HouseWorker {
        let role = row.worker.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HouseWorker(
            id         : row.id,
            name       : row.name,
            status     : status(
                needsConfiguring  : row.needsConfiguring,
                provider          : provider,
                isAwaitingApproval: isAwaitingApproval,
                isAnswering       : isAnswering,
                unreadReplies     : row.unread.replies
            ),
            activity   : row.activity ?? (isAnswering ? "Working" : role),
            role       : role,
            category   : .general,
            shape      : row.worker.shape,
            badge      : badge(
                of              : row,
                showsUnreadCount: showsUnreadCount
            ),
            usesScreen : usesScreen,
            needsSetup : row.needsConfiguring,
            spokenLabel: row.accessibilityLabel
        )
    }

    /// The light of a worker's room, the first that applies: off while it cannot answer (no model, a
    /// model gone, its provider not signed in, not installed or refusing it), waiting while an approval
    /// waits on the person, busy while it answers, waiting while replies are unread, otherwise free. A
    /// provider that cannot be reached or is over a limit leaves the worker free: the inspector says why.
    nonisolated static func status(
        needsConfiguring  : Bool,
        provider          : ConnectionState?,
        isAwaitingApproval: Bool,
        isAnswering       : Bool,
        unreadReplies     : Int
    ) -> WorkerStatus {
        if needsConfiguring { return .off }
        switch provider {
        case .credentialMissing, .notInstalled, .credentialRejected:
            return .off
        default:
            break
        }
        if isAwaitingApproval { return .waiting }
        if isAnswering { return .busy }
        return unreadReplies > 0 ? .waiting : .free
    }

    /// The attention mark for a failed or stopped turn the person has not seen, otherwise the unread
    /// replies' count when the sidebar counts them.
    nonisolated private static func badge(
        of row          : TeamRow,
        showsUnreadCount: Bool
    ) -> HouseBadge? {
        if row.needsAttention { return .attention }
        guard showsUnreadCount, row.unread.replies > 0 else { return nil }
        return .unread(row.unread.replies)
    }
}
