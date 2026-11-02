//
//  WindowStreamCostLiveTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import AppKit
import Darwin
import Foundation
import QuartzCore
import SeatCapture
import SeatCore
import Synchronization
import Testing
import WindowPlacement
@testable import SeatBroker

/// What one held-window stream costs, measured in this process: N plain windows whose content moves
/// all the time, each streamed through `PreviewStreamController` into a twin window, as the app does.
/// It runs only with `BRAUS_WINDOW_STREAM_COST=1`; `BRAUS_WINDOW_STREAM_COST_MIN` (default 1),
/// `BRAUS_WINDOW_STREAM_COST_MAX` (default 8) and
/// `BRAUS_WINDOW_STREAM_COST_SECONDS` (default 8) size it, and `BRAUS_WINDOW_STREAM_COST_CONFIGS`
/// (default "none,today,cap,tiers") picks the configurations. It prints one line per run.
@Suite("Window stream cost, live", .serialized)
@MainActor
struct WindowStreamCostLiveTests {

    nonisolated private static let environment = ProcessInfo.processInfo.environment

    /// The main window first, then palettes and dialogs of the sizes a real application opens.
    private static let sizes: [CGSize] = [
        CGSize(width: 1150, height: 750), CGSize(width: 90, height: 530), CGSize(width: 420, height: 160),
        CGSize(width: 815, height: 125), CGSize(width: 550, height: 120), CGSize(width: 420, height: 160),
        CGSize(width: 815, height: 125), CGSize(width: 550, height: 120),
    ]

    @Test("held-window streams: CPU, WindowServer CPU, fps and memory for N windows",
          .enabled(if: environment["BRAUS_WINDOW_STREAM_COST"] == "1"))
    func measure() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        keepProcessAlive()
        guard CGPreflightScreenCaptureAccess() else {
            Issue.record("Screen Recording is not granted to this process")
            return
        }
        let maximum = Int(Self.environment["BRAUS_WINDOW_STREAM_COST_MAX"] ?? "") ?? 8
        let minimum = min(maximum, Int(Self.environment["BRAUS_WINDOW_STREAM_COST_MIN"] ?? "") ?? 1)
        let seconds = Double(Self.environment["BRAUS_WINDOW_STREAM_COST_SECONDS"] ?? "") ?? 8
        let configs = (Self.environment["BRAUS_WINDOW_STREAM_COST_CONFIGS"] ?? "none,today,cap,tiers")
            .split(separator: ",").map(String.init)
        let screen  = try #require(NSScreen.screens.first)
        let scale   = screen.backingScaleFactor
        let sources = (0..<maximum).map { index in
            SceneWindow(size: Self.sizes[index % Self.sizes.count], index: index, screen: screen)
        }
        defer { sources.forEach { $0.close() } }
        print("window-stream-cost: screen \(screen.frame.size) at \(scale)x, \(seconds) s per run, "
            + "load \(Self.loadAverage())")

        for config in configs {
            for count in minimum...maximum {
                let shown = Array(sources.prefix(count))
                for (index, source) in sources.enumerated() { index < count ? source.show() : source.hide() }
                await pumpAndDrain(for: 0.5)
                let qualities = Self.qualities(config, shown.map(\.window.frame.size), viewScale: scale)
                var streams: [TwinStream] = []
                if let qualities {
                    for (source, quality) in zip(shown, qualities) {
                        let stream = try TwinStream(source: source, quality: quality, viewScale: scale)
                        streams.append(stream)
                        // One start at a time, as windows open: a burst of starts meets the kit's
                        // own bound on framework calls in flight, which is not ScreenCaptureKit's.
                        await stream.controller.waitForPendingTransition()
                    }
                }
                await pumpAndDrain(for: 2)

                let before = Usage.read()
                let counts = streams.map(\.layer.presentedCount)
                await pumpAndDrain(for: seconds)
                let after  = Usage.read()
                let fps    = zip(streams, counts).map { Double($0.layer.presentedCount - $1) / seconds }
                print(String(
                    format: "window-stream-cost %@ N=%d cpu %.1f%% windowserver %.1f%% replayd %.1f%% footprint %.0f MB | %@",
                    config, count,
                    (after.cpu - before.cpu) / seconds * 100,
                    (after.windowServer - before.windowServer) / seconds * 100,
                    (after.replayd - before.replayd) / seconds * 100,
                    Double(after.footprint) / 1_048_576,
                    zip(streams, fps).map { stream, fps in
                        let pixels = stream.quality.pixelSize(of: stream.source.window.frame.size)
                        let failure = fps > 0 ? "" : " (\(stream.controller.availability))"
                        return String(format: "%dx%d@%d:%.1f", Int(pixels.width), Int(pixels.height),
                                      stream.quality.framesPerSecond, fps) + failure
                    }.joined(separator: " ")
                ))
                for stream in streams { await stream.stop() }
                await pumpAndDrain(for: 0.5)
            }
        }
    }

    /// The quality each window streams at under `config`, nil for no stream.
    private static func qualities(_ config: String, _ sizes: [CGSize], viewScale: CGFloat) -> [WindowStreamQuality]? {
        let full = WindowStreamQuality(scale: viewScale, framesPerSecond: 10)
        switch config {
        case "today":
            return sizes.indices.map { $0 == 0 ? WindowStreamQuality(scale: viewScale, framesPerSecond: 30) : full }
        case "cap":
            return sizes.indices.map { $0 == 0 ? WindowStreamTiers.mainQuality(size: sizes[0], viewScale: viewScale) : full }
        case "tiers":
            // The newest window is fresh, the main window in front of the others.
            let windows = sizes.enumerated().map { index, size in
                WindowStreamTiers.Window(number: index, size: size, viewScale: viewScale,
                                         isMain: index == 0, isFresh: index == sizes.count - 1 && index > 0)
            }
            let qualities = WindowStreamTiers.qualities(for: windows)
            return sizes.indices.map { qualities[$0]! }
        default:
            return nil
        }
    }

    private static func loadAverage() -> String {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) > 0 ? String(format: "%.2f", load[0]) : "?"
    }
}

/// A plain window whose content moves every display tick: a bar sweeps across it and a line of text
/// stays still, drawn by Core Animation so the scene itself costs this process almost nothing.
@MainActor
private final class SceneWindow {
    let window: NSWindow
    private let bar = CALayer()

    init(size: CGSize, index: Int, screen: NSScreen) {
        let visible = screen.visibleFrame
        let origin  = CGPoint(x: visible.minX + CGFloat(index % 4) * 30, y: visible.maxY - size.height - CGFloat(index % 6) * 40)
        window = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.titled],
                          backing: .buffered, defer: false, screen: screen)
        window.title = "Window stream cost \(index)"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        bar.frame = CGRect(x: 0, y: 0, width: 40, height: size.height)
        bar.backgroundColor = NSColor.systemTeal.cgColor
        view.layer?.addSublayer(bar)
        let text = CATextLayer()
        text.string = "Window stream cost 0123456789 the quick brown fox"
        text.fontSize = 11
        text.contentsScale = screen.backingScaleFactor
        text.frame = CGRect(x: 8, y: size.height - 40, width: size.width - 16, height: 16)
        view.layer?.addSublayer(text)
        window.contentView = view
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = 0
        sweep.toValue = size.width
        sweep.duration = 1.3
        sweep.repeatCount = .infinity
        sweep.autoreverses = true
        bar.add(sweep, forKey: "sweep")
    }

    func show() { if !window.isVisible { window.orderFrontRegardless() } }
    func hide() { if window.isVisible { window.orderOut(nil) } }
    func close() { window.close() }
}

/// One window's stream into a twin window beside it, as `WindowPreviewStreams` streams a held window.
@MainActor
private final class TwinStream {
    let source    : SceneWindow
    let quality   : WindowStreamQuality
    let controller: PreviewStreamController
    let layer     = CountingLayer()
    private let twin: NSWindow

    init(source: SceneWindow, quality: WindowStreamQuality, viewScale: CGFloat) throws {
        self.source  = source
        self.quality = quality
        let number   = source.window.windowNumber
        let identity = try #require(WindowIdentityWitness().identity(of: number))
        controller = PreviewStreamController(activeFramesPerSecond: quality.framesPerSecond)
        let size  = source.window.frame.size
        twin = NSWindow(contentRect: source.window.frame.offsetBy(dx: 360, dy: 0), styleMask: [.borderless],
                        backing: .buffered, defer: false)
        twin.isReleasedWhenClosed = false
        let host = NSView(frame: CGRect(origin: .zero, size: size))
        host.wantsLayer = true
        layer.contentsScale = viewScale
        layer.contentsGravity = .resizeAspect
        layer.frame = host.bounds
        host.layer?.addSublayer(layer)
        twin.contentView = host
        twin.orderFrontRegardless()
        controller.attach(layer)
        // Two agreeing readings, as `WindowPreviewStreams.configure` gives a rescale.
        let pixels = quality.pixelSize(of: size)
        controller.follow(identity: identity, frame: source.window.frame, pixelSize: pixels)
        controller.follow(identity: identity, frame: source.window.frame, pixelSize: pixels)
    }

    func stop() async {
        controller.detach(layer)
        await controller.stop()
        twin.close()
    }
}

/// Counts what reached the twin's layer.
private final class CountingLayer: MonitorLayer, @unchecked Sendable {
    private let count = Atomic<Int>(0)
    var presentedCount: Int { count.load(ordering: .relaxed) }

    override func present(_ frame: SeatFrame) {
        super.present(frame)
        count.wrappingAdd(1, ordering: .relaxed)
    }
}

/// This process's CPU seconds and footprint, and the CPU seconds of WindowServer and replayd.
private struct Usage {
    let cpu         : Double
    let footprint   : UInt64
    let windowServer: Double
    let replayd     : Double

    static func read() -> Usage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info  = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Usage(cpu: cpu, footprint: read == KERN_SUCCESS ? info.phys_footprint : 0,
                     windowServer: cpuSeconds(of: "WindowServer"), replayd: cpuSeconds(of: "replayd"))
    }

    /// Cumulative CPU time from `ps`, read-only: another user's process refuses `proc_pid_rusage`.
    private static func cpuSeconds(of name: String) -> Double {
        let output = run("/usr/bin/pgrep", ["-x", name]).split(separator: "\n").first.map(String.init) ?? ""
        guard !output.isEmpty else { return 0 }
        let time = run("/bin/ps", ["-o", "time=", "-p", output]).trimmingCharacters(in: .whitespacesAndNewlines)
        // "m:ss.ss", or "h:mm:ss" past an hour on some systems.
        return time.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe    = Pipe()
        process.executableURL  = URL(fileURLWithPath: path)
        process.arguments      = arguments
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// A main-queue timer for the whole run: an async test main ends the process with `exit(0)` once
/// the main queue is empty, which a suspended body is enough for (see `AppKitPump`).
@MainActor
private func keepProcessAlive() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { keepProcessAlive() }
}

/// Gives the main thread back to its run loop, which draws the windows and delivers the frames:
/// pumping AppKit from inside the body instead made the async main's drain return and exit.
@MainActor
private func pumpAndDrain(for seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
}
