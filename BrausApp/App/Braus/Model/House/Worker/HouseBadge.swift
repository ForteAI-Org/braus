//
//  HouseBadge.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// HouseBadge is the mark a worker's room or row carries: something needs attention,
/// or some messages are unread.
nonisolated enum HouseBadge: Equatable, Sendable {
    case attention
    case unread(Int)
}
