//
//  FrontClicks.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics

/// FrontClicks borrows the Seat's per-process click route for one front lease.
/// Coordinates are global screen points. Each call is one attempt, never retried,
/// and throws on refusal, cancellation or an ended lease. A returned call proves
/// posting only, not an application effect. Retaining this value does not extend
/// the lease; its adapter must refuse every call after the lease ends.
@MainActor
public struct FrontClicks {

    /// Modifiers names the keys held on each button down and up.
    nonisolated public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift   = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// Receipt records where a click was posted, without proving its effect.
    /// `needsRecovery` means input preparation was not restored after posting;
    /// the click must not be replayed to compensate for that cleanup failure.
    nonisolated public struct Receipt: Sendable, Equatable {
        public let processID    : Int32
        public let windowNumber : Int
        public let location     : CGPoint
        public let eventCount   : Int
        public let needsRecovery: Bool

        public init(
            processID    : Int32,
            windowNumber : Int,
            location     : CGPoint,
            eventCount   : Int,
            needsRecovery: Bool
        ) {
            self.processID     = processID
            self.windowNumber  = windowNumber
            self.location      = location
            self.eventCount    = eventCount
            self.needsRecovery = needsRecovery
        }
    }

    private let active: @MainActor () -> Bool
    private let left  : @MainActor (CGPoint, Int, Modifiers) async throws -> Receipt
    private let right : @MainActor (CGPoint, Modifiers) async throws -> Receipt

    /// Supplies the lease-bound route. The adapter owns lifetime checks and must
    /// propagate failures without retrying or reporting an unposted click as success.
    public init(
        isActive  : @escaping @MainActor () -> Bool,
        click     : @escaping @MainActor (CGPoint, Int, Modifiers) async throws -> Receipt,
        rightClick: @escaping @MainActor (CGPoint, Modifiers) async throws -> Receipt
    ) {
        self.active = isActive
        self.left   = click
        self.right  = rightClick
    }

    /// Whether the lease is still active and the calling task is not cancelled.
    public var isActive: Bool { active() }

    /// Posts `count` left clicks through the Seat, or throws the input failure.
    @discardableResult
    public func click(
        at point : CGPoint,
        count    : Int = 1,
        modifiers: Modifiers = []
    ) async throws -> Receipt {
        try await left(
            point,
            count,
            modifiers
        )
    }

    /// Posts one right click through the Seat, or throws the input failure.
    @discardableResult
    public func rightClick(
        at point : CGPoint,
        modifiers: Modifiers = []
    ) async throws -> Receipt {
        try await right(
            point,
            modifiers
        )
    }
}
