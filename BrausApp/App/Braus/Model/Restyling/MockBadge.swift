//
//  MockBadge.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// MockBadge is the mark a worker's row carries: something needs attention,
/// or some messages are unread.
nonisolated enum MockBadge: Equatable, Sendable {
    case attention
    case unread(Int)
}
