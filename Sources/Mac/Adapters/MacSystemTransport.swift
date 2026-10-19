import AppKit
import AudioToolbox
import CoreAudio
import CoreWLAN
import Foundation

/// MacSystemTransport reaches the Mac's settings through their public interfaces: `defaults` for the
/// appearance and System Events (one fixed script) to change it, CoreAudio for the default output
/// device, CoreWLAN for Wi-Fi. It keeps no state; every read asks the system again.
public struct MacSystemTransport: SystemTransporting {

    public init() {}

    // MARK: Appearance

    public func appearance() async throws -> SystemAppearance {
        if try Self.defaults(["read", "-g", "AppleInterfaceStyleSwitchesAutomatically"]) == "1" { return .auto }
        return try Self.defaults(["read", "-g", "AppleInterfaceStyle"]) == "Dark" ? .dark : .light
    }

    public func setAppearance(dark: Bool) async throws {
        try await Self.runAppearanceScript(dark: dark)
    }

    public func appearanceAccess() async -> AdapterAvailability {
        AppleScriptRunner.availability(bundleID: Self.systemEvents, app: "System Events")
    }

    public func requestAppearanceAccess() async -> AdapterAvailability {
        await AppleScriptRunner.requestPermission(bundleID: Self.systemEvents, app: "System Events")
    }

    /// The value of a `defaults` read, nil when the key is not set (`defaults` exits 1 then).
    private static func defaults(_ arguments: [String]) throws -> String? {
        let process = Process()
        let output  = Pipe()
        process.executableURL  = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments      = arguments
        process.standardOutput = output
        process.standardError  = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let systemEvents = "com.apple.systemevents"

    /// Sets dark mode through System Events, after checking without asking that Braus may send it
    /// Apple events: a Mac that would show the consent prompt answers `SystemPermissionNeeded`.
    @MainActor
    private static func runAppearanceScript(dark: Bool) async throws {
        try await ensureSystemEventsRuns()
        var target = AEAddressDesc()
        let bundleID = Array(systemEvents.utf8)
        AECreateDesc(typeApplicationBundleID, bundleID, bundleID.count, &target)
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        switch Int(status) {
            case Int(noErr):
                break
            case Int(errAEEventWouldRequireUserConsent), Int(errAEEventNotPermitted):
                throw SystemPermissionNeeded("Braus may not control System Events yet. The person allows it in "
                                             + "System Settings > Privacy & Security > Automation.")
            default:
                throw AdapterFailure("System Events could not be reached (\(status)).")
        }
        let source = "tell application id \"\(systemEvents)\" to tell appearance preferences to set dark mode to \(dark)"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw AdapterFailure("The appearance script did not compile.") }
        script.executeAndReturnError(&error)
        if let error { throw AdapterFailure("System Events refused the appearance change: \(error).") }
    }

    /// Starts System Events in the background when it is not running, since the permission check needs
    /// a running target. It has no window and is not activated.
    @MainActor
    private static func ensureSystemEventsRuns() async throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: systemEvents).isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemEvents) else {
            throw AdapterFailure("System Events is not installed.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    // MARK: Volume

    public func volume() async throws -> SystemVolume {
        let device = try Self.outputDevice()
        var scalar = Float32(0)
        try Self.read(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, into: &scalar)
        var muted: Bool?
        if Self.has(device, kAudioDevicePropertyMute) {
            var flag = UInt32(0)
            try Self.read(device, kAudioDevicePropertyMute, into: &flag)
            muted = flag != 0
        }
        return SystemVolume(level: Int((scalar * 100).rounded()), isMuted: muted)
    }

    public func setVolume(level: Int?, muted: Bool?) async throws {
        let device = try Self.outputDevice()
        if let level {
            var scalar = Float32(min(max(level, 0), 100)) / 100
            try Self.write(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &scalar)
        }
        if let muted {
            var flag = UInt32(muted ? 1 : 0)
            try Self.write(device, kAudioDevicePropertyMute, &flag)
        }
    }

    private static func outputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size   = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { throw AdapterFailure("No output device (\(status)).") }
        return device
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func has(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        return AudioObjectHasProperty(device, &address)
    }

    private static func read<Value>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    into value: inout Value) throws {
        var address = address(selector)
        var size    = UInt32(MemoryLayout<Value>.size)
        let status  = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AdapterFailure("The output device did not answer (\(status)).") }
    }

    private static func write<Value>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                     _ value: inout Value) throws {
        var address = address(selector)
        let status  = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Value>.size), &value)
        guard status == noErr else { throw AdapterFailure("The output device refused the change (\(status)).") }
    }

    // MARK: Wi-Fi

    public func wifiPower() async throws -> Bool? {
        CWWiFiClient.shared().interface()?.powerOn()
    }

    public func setWifiPower(_ isOn: Bool) async throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw AdapterFailure("This Mac has no Wi-Fi.") }
        try interface.setPower(isOn)
    }
}
