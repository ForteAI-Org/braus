//
//  CanvasRecordingTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MacDriver
import Testing
import UniformTypeIdentifiers

/// CanvasRecordingTests is an explicit desktop recorder, invoked by CanvasFixture/record.sh.
/// Real apps write only to BRAUS_CANVAS_RECORDINGS (default ~/Downloads/Braus-canvas-recordings),
/// outside repositories. Only the newly launched instance is terminated, even on capture failure.
@Suite(
    "Opt-in canvas recordings",
    .serialized
)
@MainActor
struct CanvasRecordingTests {

    private let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ["fixture", "real"].contains(ProcessInfo.processInfo.environment["BRAUS_CANVAS_RECORD"] ?? "")))
    func record() async throws {
        let mode = try #require(environment["BRAUS_CANVAS_RECORD"])
        let appURL = URL(fileURLWithPath: try #require(environment["BRAUS_CANVAS_APP"]))
        let work = URL(fileURLWithPath: try #require(environment["BRAUS_CANVAS_WORK"]))
        let arguments = try JSONDecoder().decode(
            [String].self,
            from: Data((environment["BRAUS_CANVAS_ARGS"] ?? "[]").utf8)
        )
        let reader = LiveMacTreeReader()
        try #require(
            reader.isTrusted,
            "Accessibility permission is required"
        )
        try #require(
            CGPreflightScreenCaptureAccess(),
            "Screen Recording permission is required"
        )

        let destination: URL
        let variants: [(String, [String])]
        if mode == "fixture" {
            try #require(Bundle(url: appURL)?.bundleIdentifier == "com.braus.fixture.canvas")
            destination = CanvasFixtures.directory
            variants =
                [
                    ("still", ["--still"]),
                    ("clip-moved", ["--still", "--clip-offset", "2:120"]),
                ]
                + (0..<6).map { index in
                    (
                        "meter-phases/\(index)",
                        ["--still", "--meter-phase", String(Double(index) / 5)]
                    )
                }
        } else {
            let base =
                environment["BRAUS_CANVAS_RECORDINGS"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Downloads/Braus-canvas-recordings"
                )
            destination = try Self.realDestination(
                base: base,
                work: work
            )
            variants = [("capture", arguments)]
        }

        for (
            variant,
            flags
        ) in variants {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.addsToRecentItems = false
            configuration.activates = mode != "fixture"
            configuration.arguments = flags
            let previous = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            let app: NSRunningApplication
            if mode == "real", let document = environment["BRAUS_CANVAS_DOCUMENT"] {
                app = try await NSWorkspace.shared.open(
                    [URL(fileURLWithPath: document)],
                    withApplicationAt: appURL,
                    configuration    : configuration
                )
            } else {
                app = try await NSWorkspace.shared.openApplication(
                    at           : appURL,
                    configuration: configuration
                )
            }
            // Refuse a reused instance before installing cleanup, so an existing app is never quit.
            try #require(
                !previous.contains(app.processIdentifier),
                "The app reused an existing process"
            )
            do {
                try await capture(
                    app        : app,
                    flags      : flags,
                    variant    : variant,
                    destination: destination,
                    work       : work,
                    reader     : reader,
                    atOneScale : mode == "fixture"
                )
            } catch {
                await quit(app)
                throw error
            }
            await quit(app)
        }
        print("CANVAS_RECORDINGS \(destination.path)")
    }

    private func capture(
        app        : NSRunningApplication,
        flags      : [String],
        variant    : String,
        destination: URL,
        work       : URL,
        reader     : LiveMacTreeReader,
        atOneScale : Bool
    ) async throws {
        let pid = app.processIdentifier
        var candidate: (number: Int, frame: CGRect, window: MacWindowSummary)?
        var stableSamples = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        repeat {
            let rows =
                CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements],
                    kCGNullWindowID
                )
                as? [[String: Any]] ?? []
            let windows: [MacWindowSummary]
            do {
                windows = try await reader.windows(of: pid)
            } catch MacTreeFailure.applicationUnreachable(_) {
                // Launch completion can precede registration of the app's AXWindows attribute.
                windows = []
            }
            let matching = rows.compactMap { info -> (Int, CGRect, MacWindowSummary)? in
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                    (info[kCGWindowLayer as String] as? Int) == 0,
                    let number = info[kCGWindowNumber as String] as? Int,
                    let bounds = info[kCGWindowBounds as String] as? [String: Any]
                else { return nil }
                var frame = CGRect.zero
                guard
                    CGRectMakeWithDictionaryRepresentation(
                        bounds as CFDictionary,
                        &frame
                    ),
                    windows.filter({ $0.frame == frame && !$0.isMinimized }).count == 1,
                    let window = windows.first(where: { $0.frame == frame && !$0.isMinimized })
                else { return nil }
                if let document = environment["BRAUS_CANVAS_DOCUMENT"],
                    !window.shows(URL(fileURLWithPath: document))
                {
                    return nil
                }
                return (
                    number,
                    frame,
                    window
                )
            }
            if let match = matching.first {
                stableSamples = candidate?.number == match.0 && candidate?.frame == match.1 ? stableSamples + 1 : 1
                candidate = match
            } else {
                stableSamples = 0
                candidate = nil
            }
            if stableSamples >= 5 { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        try #require(
            stableSamples >= 5,
            "No stable matching AX and on-screen window for the requested document"
        )
        let (
            number,
            frame,
            window
        ) = try #require(candidate)
        let read = try await reader.read(
            windowAt: window.index,
            of      : pid,
            limits  : MacTreeLimits(deadline: 10)
        )
        try #require(
            read.stoppedBy == nil,
            "AX recording exceeded its walk limits"
        )
        try #require(
            read.window.frame == frame && read.window.title == window.title,
            "The window changed during its AX read"
        )
        try await validateCurrentCapture(
            window   : window,
            number   : number,
            processID: pid,
            reader   : reader
        )
        if atOneScale {
            try #require(
                !read.window.hasUnreadParts,
                "Fixture AX read was partial"
            )
        }

        let output = destination.appendingPathComponent(variant)
        try FileManager.default.createDirectory(
            at                         : output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let raw = work.appendingPathComponent("native-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(number), raw.path]
        try process.run()
        process.waitUntilExit()
        try #require(
            process.terminationStatus == 0,
            "screencapture failed"
        )
        try await validateCurrentCapture(
            window   : window,
            number   : number,
            processID: pid,
            reader   : reader
        )
        let source = try #require(
            CGImageSourceCreateWithURL(
                raw as CFURL,
                nil
            )
        )
        let native = try #require(
            CGImageSourceCreateImageAtIndex(
                source,
                0,
                nil
            )
        )
        let scaleX = Double(native.width) / frame.width
        let scaleY = Double(native.height) / frame.height
        try #require(
            scaleX >= 1 && abs(scaleX - scaleY) < 0.01,
            "PNG dimensions do not match the window frame"
        )
        let image: CGImage
        if atOneScale {
            let colourSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(
                CGContext(
                    data            : nil,
                    width           : Int(frame.width),
                    height          : Int(frame.height),
                    bitsPerComponent: 8,
                    bytesPerRow     : 0,
                    space           : colourSpace,
                    bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.interpolationQuality = .high
            context.draw(
                native,
                in: CGRect(
                    origin: .zero,
                    size  : frame.size
                )
            )
            image = try #require(context.makeImage())
        } else {
            image = native
        }
        let png = try #require(
            CGImageDestinationCreateWithURL(
                output.appendingPathExtension("png") as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            png,
            image,
            nil
        )
        try #require(CGImageDestinationFinalize(png))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(read.window).write(
            to     : output.appendingPathExtension("json"),
            options: .atomic
        )
        let metadata = Metadata(
            bundleID    : app.bundleIdentifier ?? "",
            arguments   : flags,
            windowNumber: number,
            windowFrame : frame,
            nativeWidth : native.width,
            nativeHeight: native.height,
            storedWidth : image.width,
            storedHeight: image.height
        )
        try encoder.encode(metadata).write(
            to     : output.appendingPathExtension("capture.json"),
            options: .atomic
        )
        print(
            "CANVAS_CAPTURE \(variant) pid=\(pid) window=\(number) native=\(native.width)x\(native.height) stored=\(image.width)x\(image.height) nodes=\(read.nodesVisited) unread=\(read.unread.nodes)"
        )
    }

    private struct Metadata: Encodable {
        let bundleID: String
        let arguments: [String]
        let windowNumber: Int
        let windowFrame: CGRect
        let nativeWidth: Int
        let nativeHeight: Int
        let storedWidth: Int
        let storedHeight: Int
    }

    private func validateCurrentCapture(
        window   : MacWindowSummary,
        number   : Int,
        processID: pid_t,
        reader   : LiveMacTreeReader
    ) async throws {
        let windows = try await reader.windows(of: processID)
        let rows =
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            )
            as? [[String: Any]] ?? []
        try Self.validateCapture(
            window   : window,
            number   : number,
            processID: processID,
            windows  : windows,
            rows     : rows
        )
    }

    /// Rejects moved, replaced, reordered or ambiguous windows instead of pairing unrelated trees and pixels.
    static func validateCapture(
        window   : MacWindowSummary,
        number   : Int,
        processID: pid_t,
        windows  : [MacWindowSummary],
        rows     : [[String: Any]]
    ) throws {
        guard windows.filter({ $0.frame == window.frame }) == [window] else { throw RecordingFailure.windowChanged }
        let matching = rows.filter { row in
            guard (row[kCGWindowOwnerPID as String] as? pid_t) == processID,
                (row[kCGWindowLayer as String] as? Int) == 0,
                let bounds = row[kCGWindowBounds as String] as? [String: Any]
            else { return false }
            var frame = CGRect.zero
            return CGRectMakeWithDictionaryRepresentation(
                bounds as CFDictionary,
                &frame
            ) && frame == window.frame
        }
        guard matching.count == 1, matching[0][kCGWindowNumber as String] as? Int == number else {
            throw RecordingFailure.windowChanged
        }
    }

    /// Resolves symlinks and rejects every ancestor containing a Git marker, including worktrees.
    static func requireOutsideRepository(_ url: URL) throws {
        var ancestor = url.standardizedFileURL.resolvingSymlinksInPath()
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                throw RecordingFailure.repositoryDestination
            }
            ancestor.deleteLastPathComponent()
        }
    }

    /// Validates both output locations before launch, including the temporary native screenshot.
    static func realDestination(
        base: URL,
        work: URL
    ) throws -> URL {
        try requireOutsideRepository(base)
        try requireOutsideRepository(work)
        return base.appendingPathComponent(UUID().uuidString)
    }

    enum RecordingFailure: Error, Equatable {
        case repositoryDestination
        case windowChanged
    }

    private func quit(_ app: NSRunningApplication) async {
        app.terminate()
        for _ in 0..<20 {
            if app.isTerminated { return }
            // Cancellation must not skip owned-process cleanup.
            try? await Task.sleep(for: .milliseconds(100))
        }
        app.forceTerminate()
        for _ in 0..<20 {
            if app.isTerminated { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(
            app.isTerminated,
            "Launched process \(app.processIdentifier) did not terminate"
        )
    }
}
