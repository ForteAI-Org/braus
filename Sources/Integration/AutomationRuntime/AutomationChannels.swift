//
//  AutomationChannels.swift
//  Braus
//

import Foundation

/// AutomationChannels names the routes beyond the Seat that one composition of Braus turns on: the
/// MacDriver before the Seat (`native`), Braus's own Chrome (`web`) and app adapters (`adapters`).
/// The empty set keeps every app on the Seat, with no adapter tool or routing advice.
///
/// A composition root (the app, the command line) reads it once, at start, and hands it to what it
/// builds; reusable modules receive it and never read it from the environment themselves. Turning a
/// channel on grants no authority: each route still applies its own consent, permissions and policy.
nonisolated public struct AutomationChannels: OptionSet, Sendable, Hashable, CustomStringConvertible {

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Native apps go to the MacDriver first, and to the Seat when it gives them back.
    public static let native     = AutomationChannels(rawValue: 1 << 0)
    /// `web:<host>` and URLs go to Braus's own Chrome profile, and `open_session` asks the router.
    public static let web        = AutomationChannels(rawValue: 1 << 1)
    /// `app_capabilities` and `app_call` reach the app adapters.
    public static let adapters   = AutomationChannels(rawValue: 1 << 2)

    public static let all: AutomationChannels = [.native, .web, .adapters]

    /// The names a list spells, in this order.
    static let names: [(String, AutomationChannels)] = [
        ("native", .native), ("web", .web), ("adapters", .adapters),
    ]

    /// Parses a comma separated list of names (`native,web`), `all`, or `none` and the empty text for
    /// the empty set. Spaces around a name and case are ignored.
    ///
    /// - Throws: `AutomationFailure` naming the first word that is not a channel, so a typo never
    ///   composes fewer routes than the person asked for without saying so.
    public init(parsing list: String) throws {
        var parsed: AutomationChannels = []
        for word in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch word {
                case "", "none": continue
                case "all"     : parsed.formUnion(.all)
                default:
                    guard let channel = Self.names.first(where: { $0.0 == word })?.1 else {
                        throw AutomationFailure("'\(word)' is not a channel: use native, web, adapters, "
                                                + "all or none.")
                    }
                    parsed.insert(channel)
            }
        }
        self = parsed
    }

    /// The names of the channels in the set, comma separated, or `none`.
    public var description: String {
        let present = Self.names.filter { contains($0.1) }.map(\.0)
        return present.isEmpty ? "none" : present.joined(separator: ",")
    }
}
