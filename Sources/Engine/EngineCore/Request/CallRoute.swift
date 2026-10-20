//
//  CallRoute.swift
//  Braus
//

/// CallRoute is the route a routing session dispatched a call on (M05): the MacDriver in the app where it is
/// (`native`), the seat (`desktop`) or Braus's browser engine (`web`), and, when the MacDriver gave the app back to
/// the desktop during the call, the reason it gave. It is what the session did, never what was asked or advised.
public struct CallRoute: Sendable, Equatable {

    public enum Route: String, Sendable, Equatable, Hashable, CaseIterable {
        case native, desktop, web
    }

    public let route: Route
    /// Why the MacDriver gave the app back to the desktop during the call; nil when it did not. Only the desktop
    /// takes an app back, and a hand-back always has a reason.
    public let handoffReason: String?

    /// The route, with the reason of a hand-back to the desktop; a reason is kept only on the desktop, and an
    /// empty one is said as none given, so a hand-back is never lost.
    public init(_ route: Route, handoffReason: String? = nil) {
        self.route = route
        self.handoffReason = route == .desktop ? handoffReason.map { $0.isEmpty ? Self.noReason : $0 } : nil
    }

    /// What a hand-back whose reason is empty is recorded with.
    public static let noReason = "The MacDriver gave the app back without a reason."
}
