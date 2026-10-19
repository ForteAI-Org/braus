import EngineCore
import LocalMCP

/// SystemTransporting is the Mac's own settings as the System adapter reaches them. The live one is
/// `MacSystemTransport`; tests use a fake that records what was set.
public protocol SystemTransporting: Sendable {
    func appearance() async throws -> SystemAppearance
    /// Sets light or dark. Throws `SystemPermissionNeeded` when the Mac would have to ask first.
    func setAppearance(dark: Bool) async throws
    func volume() async throws -> SystemVolume
    func setVolume(level: Int?, muted: Bool?) async throws
    /// Whether the Wi-Fi radio is on; nil when the Mac has no Wi-Fi interface.
    func wifiPower() async throws -> Bool?
    func setWifiPower(_ isOn: Bool) async throws
    /// Whether Braus may control System Events, which `setAppearance` needs, as the Mac answers without prompting.
    func appearanceAccess() async -> AdapterAvailability
    /// Starts System Events hidden and not activated when it is not running, so `appearanceAccess` can read its
    /// grant: the Mac answers it only for a running target. Starting it never prompts.
    func startSystemEvents() async throws
    /// Asks the person whether Braus may control System Events, prompting when they have not answered yet. Only on
    /// the person's request.
    func requestAppearanceAccess() async -> AdapterAvailability
}

public enum SystemAppearance: String, Sendable, Equatable {
    case light, dark, auto
}

/// SystemVolume is the default output device's level, 0 to 100, and whether it is muted (nil when
/// the device has no mute).
public struct SystemVolume: Sendable, Equatable {
    public let level  : Int
    public let isMuted: Bool?

    public init(level: Int, isMuted: Bool?) {
        self.level   = level
        self.isMuted = isMuted
    }
}

/// SystemPermissionNeeded is a setting the Mac would ask the person about before Braus could
/// change it; the adapter answers it as a refusal and never triggers the prompt.
public struct SystemPermissionNeeded: Error, Sendable, Equatable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// SystemAdapter is the Mac's settings that have an API: appearance, output volume, Wi-Fi. Setters
/// answer the value they replaced, so the agent can put it back.
///
/// Not here yet, with the reason: Bluetooth (no public setter), Focus (no public read of which mode is
/// on). Any other setting is changed in System Settings' interface, which the task router's advice
/// sends the agent to when none of these verbs does the task.
public struct SystemAdapter: AppAdapting {

    public let name       = "system"
    public let appNames   = ["System", "System Settings", "Mac settings"]
    public let bundleIDs: Set<String> = ["com.apple.systempreferences"]

    private let transport: any SystemTransporting
    /// Whether reading the availability starts System Events first, so its grant reads as the Mac has it instead of
    /// unknown. Only Braus's Settings sets it, where the person reads the grant; the tools never start it to route.
    private let startsSystemEvents: Bool

    public init(transport: any SystemTransporting, startsSystemEvents: Bool = false) {
        self.transport          = transport
        self.startsSystemEvents = startsSystemEvents
    }

    public var verbs: [AdapterVerb] {
        [
            AdapterVerb("get_appearance", "Read the Mac's appearance: light, dark or auto.",
                        safety: .read, readBack: "the global AppleInterfaceStyle setting"),
            AdapterVerb("set_appearance", "Switch the Mac to light or dark appearance.",
                        parameters: [AdapterParameter("appearance", .string, "light or dark", choices: ["light", "dark"])],
                        safety: .write, readBack: "the appearance read again"),
            AdapterVerb("get_volume", "Read the output volume (0 to 100) and whether it is muted.",
                        safety: .read, readBack: "the default output device"),
            AdapterVerb("set_volume", "Set the output volume level, mute, or both.",
                        parameters: [
                            AdapterParameter("level", .integer, "0 to 100", required: false, range: 0...100),
                            AdapterParameter("muted", .boolean, "true to mute", required: false),
                        ],
                        safety: .write, readBack: "the default output device read again"),
            AdapterVerb("get_wifi", "Read whether Wi-Fi is on.",
                        safety: .read, readBack: "the Wi-Fi interface's power"),
            AdapterVerb("set_wifi", "Turn Wi-Fi on or off.",
                        parameters: [AdapterParameter("on", .boolean, "true for on")],
                        safety: .write, readBack: "the Wi-Fi interface's power read again"),
        ]
    }

    public func availability() async -> AdapterAvailability {
        // A failed start leaves the grant unknown, which the availability below says.
        if startsSystemEvents { try? await transport.startSystemEvents() }
        return Self.availability(appearance: await transport.appearanceAccess())
    }

    public func requestPermission() async -> AdapterAvailability {
        Self.availability(appearance: await transport.requestAppearanceAccess())
    }

    /// The adapter's availability given System Events' grant. Volume and Wi-Fi need no permission, so the adapter runs
    /// without it and only `set_appearance` refuses, by itself; the state is unknown then, which lets the person's
    /// Settings offer to ask for it. A grant the Mac could not answer (System Events not running) says so apart from
    /// one it refused.
    static func availability(appearance: AdapterAvailability) -> AdapterAvailability {
        switch appearance {
            case .ready:
                return .ready
            case .unknown:
                return .unknown("Volume and Wi-Fi work. Whether Braus may change the appearance is not known while "
                                + "System Events is not running; set_appearance starts it hidden and checks first.")
            case .needsPermission, .unavailable:
                return .unknown("Volume and Wi-Fi work; changing the appearance needs Braus to control System Events, "
                                + "which the person allows in Braus's Settings.")
        }
    }

    public func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        let arguments = AdapterArguments(arguments)
        do {
            switch verb {
                case "get_appearance":
                    let appearance = try await transport.appearance()
                    return .confirmed("The appearance is \(appearance.rawValue).",
                                      .object(["appearance": .string(appearance.rawValue)]))
                case "set_appearance":
                    return try await setAppearance(dark: try arguments.required("appearance") == "dark")
                case "get_volume":
                    return .confirmed("Volume read.", Self.json(try await transport.volume()))
                case "set_volume":
                    return try await setVolume(level: arguments.number("level").map { Int($0) },
                                               muted: arguments.bool("muted"))
                case "get_wifi":
                    guard let isOn = try await transport.wifiPower() else { return .missing("This Mac has no Wi-Fi.") }
                    return .confirmed("Wi-Fi is \(isOn ? "on" : "off").", .object(["on": .bool(isOn)]))
                case "set_wifi":
                    return try await setWifi(arguments.bool("on") == true)
                default:
                    throw AdapterFailure("system has no verb \(verb).")
            }
        } catch let needed as SystemPermissionNeeded {
            return .refused(needed.reason)
        }
    }

    private func setAppearance(dark: Bool) async throws -> AdapterOutcome {
        let wanted   = dark ? SystemAppearance.dark : .light
        let previous = try await transport.appearance()
        if previous == wanted {
            return AdapterOutcome(.actedNoop, "The appearance was already \(wanted.rawValue).",
                                  result: .object(["appearance": .string(wanted.rawValue),
                                                   "previous": .string(previous.rawValue)]))
        }
        try await transport.setAppearance(dark: dark)
        let now    = try await transport.appearance()
        let result = JSONValue.object(["appearance": .string(now.rawValue), "previous": .string(previous.rawValue)])
        guard now == wanted else {
            return AdapterOutcome(.actedUnverified, "Set \(wanted.rawValue), but the Mac reads \(now.rawValue).",
                                  result: result)
        }
        return .confirmed("The appearance is \(now.rawValue); it was \(previous.rawValue).", result)
    }

    private func setVolume(level: Int?, muted: Bool?) async throws -> AdapterOutcome {
        guard level != nil || muted != nil else { return .refused("set_volume needs level, muted or both.") }
        let previous = try await transport.volume()
        if muted != nil, previous.isMuted == nil { return .refused("The output device has no mute.") }
        try await transport.setVolume(level: level, muted: muted)
        let now    = try await transport.volume()
        var result = Self.json(now)
        if case .object(var object) = result {
            object["previous"] = Self.json(previous)
            result = .object(object)
        }
        // The device stores a scalar, so a level may come back one step off.
        let levelHolds = level.map { abs(now.level - $0) <= 1 } ?? true
        let muteHolds  = muted.map { now.isMuted == $0 } ?? true
        guard levelHolds, muteHolds else {
            return AdapterOutcome(.actedUnverified, "The volume did not read back as set.", result: result)
        }
        return .confirmed("Volume \(now.level)\(now.isMuted == true ? ", muted" : "").", result)
    }

    private func setWifi(_ isOn: Bool) async throws -> AdapterOutcome {
        guard let previous = try await transport.wifiPower() else { return .missing("This Mac has no Wi-Fi.") }
        if previous == isOn {
            return AdapterOutcome(.actedNoop, "Wi-Fi was already \(isOn ? "on" : "off").",
                                  result: .object(["on": .bool(isOn), "previous": .bool(previous)]))
        }
        try await transport.setWifiPower(isOn)
        let now    = try await transport.wifiPower()
        let result = JSONValue.object(["on": now.map(JSONValue.bool) ?? .null, "previous": .bool(previous)])
        guard now == isOn else {
            return AdapterOutcome(.actedUnverified, "Wi-Fi did not read back as \(isOn ? "on" : "off").", result: result)
        }
        return .confirmed("Wi-Fi is \(isOn ? "on" : "off").", result)
    }

    private static func json(_ volume: SystemVolume) -> JSONValue {
        .object(["level": .number(Double(volume.level)), "muted": volume.isMuted.map(JSONValue.bool) ?? .null])
    }
}
