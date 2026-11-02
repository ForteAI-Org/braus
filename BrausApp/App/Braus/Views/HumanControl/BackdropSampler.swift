//
//  BackdropSampler.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import ScreenCaptureKit
import SeatBroker

/// BackdropSampler looks at what lies behind the overlay every `BackdropLight.interval` seconds: one
/// ScreenCaptureKit still of the region, scaled down to 4 by 4 pixels by the capture itself, with
/// Braus' own windows left out, or only the overlay's own when the others count (the screen window's
/// worker stands half over its window), and hands on the light it gives when it changed.
///
/// It never asks for Screen Recording: without the grant it samples nothing and the worker keeps the
/// light it has. The content filter is made once per region and reused.
final class BackdropSampler {

    /// The light of the backdrop, each time it changed enough to light the worker again.
    var onLight: ((SIMD4<Float>) -> Void)?

    /// The sampling running now, and what it has counted, for the debug check's cost line.
    private var sampling: Task<Void, Never>?
    private(set) var samples = 0

    private var filter  : SCContentFilter?
    private var light   : SIMD4<Float>?
    private var excluded: CGWindowID?

    /// Samples the backdrop behind `region`, a frame in AppKit's screen space on `screen`, until
    /// `stop()`, starting now; with `window`, the number of the overlay's own, only that window is
    /// left out.
    func start(
        region          : CGRect,
        on screen       : NSScreen,
        excluding window: Int? = nil
    ) {
        stop()
        excluded = window.map { CGWindowID($0) }
        guard CGPreflightScreenCaptureAccess() else { return }
        let display = PersonScreen.displayID(of: screen)
        // ScreenCaptureKit reads the display's points from its top-left corner.
        let source  = CGRect(
            x     : region.minX - screen.frame.minX,
            y     : screen.frame.maxY - region.maxY,
            width : region.width,
            height: region.height
        )
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample(
                    display: display,
                    source : source
                )
                try? await Task.sleep(for: .seconds(BackdropLight.interval))
            }
        }
    }

    func stop() {
        sampling?.cancel()
        sampling = nil
        filter   = nil
    }

    private func sample(
        display: CGDirectDisplayID,
        source : CGRect
    ) async {
        do {
            if filter == nil {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard let shown = content.displays.first(where: { $0.displayID == display }) else { return }
                if let excluded {
                    filter = SCContentFilter(
                        display         : shown,
                        excludingWindows: content.windows.filter { $0.windowID == excluded }
                    )
                } else {
                    let own = content.applications.filter { $0.processID == getpid() }
                    filter = SCContentFilter(
                        display              : shown,
                        excludingApplications: own,
                        exceptingWindows     : []
                    )
                }
            }
            guard let filter, !Task.isCancelled else { return }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect  = source
            configuration.width       = 4
            configuration.height      = 4
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            samples += 1
            guard
                !Task.isCancelled,
                let backdrop = BackdropLight.average(of: Self.pixels(of: image))
            else { return }
            let new = BackdropLight.light(for: backdrop)
            if let light, !BackdropLight.differs(new, from: light) { return }
            light = new
            onLight?(new)
        } catch {
            // A refused or failed capture leaves the light as it is; the next interval tries again.
        }
    }

    /// The RGBA bytes of `image`, drawn into a context of its own size.
    private static func pixels(of image: CGImage) -> [UInt8] {
        let width  = image.width
        let height = image.height
        var bytes  = [UInt8](repeating: 0, count: 4 * width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data            : buffer.baseAddress,
                width           : width,
                height          : height,
                bitsPerComponent: 8,
                bytesPerRow     : 4 * width,
                space           : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(
                image,
                in: CGRect(
                    x     : 0,
                    y     : 0,
                    width : width,
                    height: height
                )
            )
        }
        return bytes
    }
}
