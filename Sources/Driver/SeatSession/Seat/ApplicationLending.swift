//
//  ApplicationLending.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore

/// ApplicationLendingReport records verified moves and individual failures. A partial result
/// keeps agent input paused; the caller must resolve it or end the lease.
nonisolated public struct ApplicationLendingReport: Sendable {
    public struct Move: Sendable {
        public let window: WindowIdentity
        public let before: CGRect
        public let after: CGRect
    }

    public struct Failure: Sendable {
        public let windowNumber: Int
        public let reason: String
    }

    public enum Activation: String, Sendable {
        case notAttempted
        case verified
        case unverified
    }

    public init() {}

    /// Human ownership survives an unverified activation or a partial transfer.
    public internal(set) var personHasControl = false
    public internal(set) var activation: Activation = .notAttempted
    public internal(set) var activationWindow: WindowIdentity?
    public internal(set) var activationAttempts = 0

    public internal(set) var moves: [Move] = []
    public internal(set) var failures: [Failure] = []
    public internal(set) var wasClamped = false
    public internal(set) var applicationVanished = false
}

/// ApplicationLendingLayout places windows at independent destinations or a relative group fallback, preserving size.
/// An oversized axis is aligned to the visible frame's leading edge, keeping title bars reachable.
nonisolated struct ApplicationLendingLayout {
    let frames: [CGRect]
    let wasClamped: Bool

    /// Centers the group on the visible frame or, with an anchor, centers the front window on the anchor; the group
    /// keeps its relative layout and stays inside the visible frame when it fits.
    /// Destinations align with frames and override individual origins after the group is placed.
    /// They retain each window's size; missing or nonfinite origins keep the group placement.
    init(
        frames: [CGRect],
        visibleFrame: CGRect,
        anchor: (front: Int, center: CGPoint)? = nil,
        destinations: [CGRect?] = []
    ) {
        let group = frames.reduce(CGRect.null) { $0.union($1) }
        guard !group.isNull else {
            self.frames = []
            wasClamped = false
            return
        }
        var clamped = false
        func place(_ length: CGFloat, _ wanted: CGFloat, _ lower: CGFloat, _ span: CGFloat) -> CGFloat {
            length > span ? lower : min(max(wanted, lower), lower + span - length)
        }
        var wanted = CGPoint(x: visibleFrame.midX - group.width / 2, y: visibleFrame.midY - group.height / 2)
        if let anchor, frames.indices.contains(anchor.front) {
            let front = frames[anchor.front]
            wanted = CGPoint(x: anchor.center.x - (front.midX - group.minX), y: anchor.center.y - (front.midY - group.minY))
        }
        let x = place(group.width, wanted.x, visibleFrame.minX, visibleFrame.width)
        let y = place(group.height, wanted.y, visibleFrame.minY, visibleFrame.height)
        self.frames = frames.enumerated().map { index, frame in
            guard destinations.indices.contains(index), let destination = destinations[index],
                  destination.origin.x.isFinite, destination.origin.y.isFinite else {
                clamped = clamped || group.width > visibleFrame.width || group.height > visibleFrame.height
                return frame.offsetBy(dx: x - group.minX, dy: y - group.minY)
            }
            let origin = CGPoint(
                x: place(frame.width, destination.origin.x, visibleFrame.minX, visibleFrame.width),
                y: place(frame.height, destination.origin.y, visibleFrame.minY, visibleFrame.height)
            )
            clamped = clamped || origin != destination.origin
                || frame.width > visibleFrame.width || frame.height > visibleFrame.height
            return CGRect(origin: origin, size: frame.size)
        }
        wasClamped = clamped
    }
}
