import AppKit
import CoreServices
import Foundation

/// MacFinderScripting is Finder's scripting interface, the API rung of `reveal`: two fixed scripts,
/// never one the agent wrote. Finder's `reveal` without `activate` selects the item in a Finder
/// window and leaves Finder behind (measured 15 Oct); `selection` reads the effect back.
public protocol MacFinderScripting: Sendable {

    /// Whether Braus may send Finder Apple events now. Never prompts: without the person's earlier
    /// consent this answers false and the caller takes the accessibility rung.
    func isPermitted() -> Bool

    func reveal(_ item: URL) async throws

    /// The items selected in Finder's front window.
    func selection() async throws -> [URL]
}

/// LiveFinderScripting runs the two scripts with `NSAppleScript` on the main actor.
public struct LiveFinderScripting: MacFinderScripting {

    public init() {}

    public func isPermitted() -> Bool {
        var target = AEAddressDesc()
        let bundle = Data(MacBackgroundOpener.finderBundleID.utf8)
        let created = bundle.withUnsafeBytes { bytes in
            AECreateDesc(DescType(typeApplicationBundleID), bytes.baseAddress, bytes.count, &target)
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false
        )
        return status == noErr
    }

    public func reveal(_ item: URL) async throws {
        _ = try await run("tell application \"Finder\" to reveal (POSIX file \(Self.quoted(item.path)) as alias)")
    }

    public func selection() async throws -> [URL] {
        let text = try await run("""
            tell application "Finder" to set picked to (get selection as alias list)
            set out to ""
            repeat with anItem in picked
                set out to out & POSIX path of anItem & linefeed
            end repeat
            return out
            """)
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    private func run(_ source: String) async throws -> String {
        try await MainActor.run {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { throw MacOpenFailure.scriptFailed("not compiled") }
            let result = script.executeAndReturnError(&error)
            if let error { throw MacOpenFailure.scriptFailed(error[NSAppleScript.errorMessage] as? String ?? "\(error)") }
            return result.stringValue ?? ""
        }
    }

    /// An AppleScript string literal: quotes and backslashes escaped.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
