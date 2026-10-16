//
//  SeatSceneProvider.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import Perception
import PerceptionCore
#if BRAUS_PHASES
import PhaseSignposts
#endif
import SeatCapture
import SeatCore
import SeatSession

/// SeatSceneProvider is `SceneProviding` for a window adopted on the Seat: a still of the window
/// through the Seat's capture, the scene pipeline on top, and the frame the still's own geometry
/// reports, so a pixel the model names maps back to the point the Seat will route.
///
/// While a pop-up is open beside the window, the still is of the whole virtual display, cropped to
/// the union of the window and the pop-up: the scene then holds the pop-up's rows and the returned
/// frame is that union. Accessibility geometry is never mixed in; the augmenter's trust rule drops
/// frames that do not intersect the captured rectangle, and on the Seat the application's own child
/// frames still point at the window's old place.
///
/// A window still whose pixels are byte for byte those the last scene was read from, of the same
/// window with the same census facts, answers that scene again without the pipeline (ADR 0034), so
/// the layer above answers "Unchanged since revision N." through its own baseline. The trade-off,
/// accepted by the owner: a change that draws nothing (an accessibility value or focus) is not seen.
/// Every call still takes a fresh observation, but a running stream's frame displayed after a Command
/// can still repeat the window's pixels from before it (a Qt window did for seconds). So a kept scene
/// answers again only when its own frame was displayed after the last Command; otherwise a still from
/// a stream started now decides, and the scene is reused only when that still matches too. The
/// display path never reuses.
public struct SeatSceneProvider: SceneProviding {

    private let target: SeatTarget
    private let pipeline: ScenePipeline
    private let windows: any WindowListing
    private let identity: @Sendable (pid_t) -> ApplicationIdentity?
    private let freshStill: @MainActor @Sendable (SeatTarget) async throws -> SeatFrame
    private let lastScene = LastScene()

    public init(
        target  : SeatTarget,
        pipeline: ScenePipeline,
        windows : any WindowListing,
        identity: @escaping @Sendable (pid_t) -> ApplicationIdentity?
    ) {
        self.init(
            target    : target,
            pipeline  : pipeline,
            windows   : windows,
            identity  : identity,
            freshStill: { try await $0.freshWindowStill() }
        )
    }

    /// `freshStill` takes the still a kept scene is confirmed against after a Command, so a test
    /// can answer it without ScreenCaptureKit.
    package init(
        target    : SeatTarget,
        pipeline  : ScenePipeline,
        windows   : any WindowListing,
        identity  : @escaping @Sendable (pid_t) -> ApplicationIdentity?,
        freshStill: @escaping @MainActor @Sendable (SeatTarget) async throws -> SeatFrame
    ) {
        self.target     = target
        self.pipeline   = pipeline
        self.windows    = windows
        self.identity   = identity
        self.freshStill = freshStill
    }

    public func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
        #if BRAUS_PHASES
        let perception = PhaseInterval.begin("perception")
        defer { perception.end() }
        // Ended only when the kept scene is answered, so the table counts and times the reuses alone.
        let reusing = PhaseInterval.begin("perception.reused")
        #endif
        let application = identity(processID)
            ?? ApplicationIdentity(bundleID: "pid.\(processID)", name: "pid \(processID)")
        // Reconcile selection and containment before deciding which surfaces need a display crop.
        #if BRAUS_PHASES
        let windowStill = PhaseInterval.begin("capture.windowStill")
        #endif
        let observation = try await target.observe()
        #if BRAUS_PHASES
        windowStill.end()
        #endif
        guard let observedWindow = await target.lastCapturedWindow else {
            throw SeatDrivingFailure.frameUnusable
        }
        // Only the windows on the seat's display: one left on the person's display is not in this scene.
        let seatBounds = await target.displayID.map(CGDisplayBounds) ?? .null
        let onSeat = try windows.windows(ownedBy: processID).filter { $0.frame.intersects(seatBounds) }
        let popups = WindowSurfaceClassifier.classify(onSeat).popups
        var image: CGImage
        let frame: CGRect
        var comparable: SeatFrame?
        if popups.isEmpty {
            let still = observation.frame
            #if BRAUS_PHASES
            let conversion = PhaseInterval.begin("capture.makeCGImage")
            #endif
            guard still.geometry.isValid, let pixels = still.makeCGImage() else {
                throw SeatDrivingFailure.frameUnusable
            }
            #if BRAUS_PHASES
            conversion.end()
            #endif
            image = pixels
            frame = still.geometry.screenRect
            comparable = still
        } else {
            #if BRAUS_PHASES
            let displayStill = PhaseInterval.begin("capture.displayStill")
            #endif
            let still = try await target.displayStill()
            #if BRAUS_PHASES
            displayStill.end()
            #endif
            guard still.geometry.isValid, let pixels = still.makeCGImage() else {
                throw SeatDrivingFailure.frameUnusable
            }
            let display = still.geometry.screenRect
            let scale = still.geometry.scaleFactor
            let windowFrame = observation.frame.geometry.screenRect
            let union = popups.reduce(windowFrame) { $0.union($1) }.intersection(display)
            let crop = CGRect(
                x     : (union.minX - display.minX) * scale,
                y     : (union.minY - display.minY) * scale,
                width : union.width * scale,
                height: union.height * scale
            ).integral
            guard let cropped = pixels.cropping(to: crop) else { throw SeatDrivingFailure.frameUnusable }
            image = cropped
            frame = union
            guard try await target.currentWindow().reference.identity == observedWindow.reference.identity else {
                throw SeatDrivingFailure.frameUnusable
            }
        }
        // Adoption keeps a recovery title; only a fresh census can name the document now displayed.
        let matchingRows = try windows.windows(ownedBy: processID).filter { $0.number == observedWindow.id }
        let currentTitle = matchingRows.count == 1 ? matchingRows[0].title ?? "" : ""
        let window = ScenePipeline.Window(
            bundleID    : application.bundleID,
            appName     : application.name,
            title       : currentTitle,
            processID   : processID,
            frame       : frame,
            windowNumber: observedWindow.id
        )
        // The union with an open pop-up is two windows in one picture, not a structural surface.
        func perceived(_ capture: SceneCapture) -> PerceivedWindow {
            let surface = popups.isEmpty
                ? CaptureSurface.classified(role: capture.quality.windowRole, subrole: capture.quality.windowSubrole)
                : CaptureSurface.popupUnion
            return PerceivedWindow(scene: capture.scene, frame: frame, capture: capture.quality, surface: surface)
        }
        // ADR 0034: the same window and census over byte-identical pixels is the scene already read.
        if let still = comparable, let kept = await lastScene.kept, kept.window == window,
           kept.frame.showsSameContent(as: still) {
            let keptDisplayedAt = kept.frame.displayTime.flatMap {
                MachAbsoluteContentClock().displayTimeNanoseconds(fromMachTicks: $0)
            }
            if Self.mayReuse(keptDisplayedAt: keptDisplayedAt, lastCommandAt: await target.lastCommandAt) {
                #if BRAUS_PHASES
                reusing.end()
                #endif
                await MainActor.run { target.lastSceneImage = image }
                return perceived(kept.capture)
            }
            #if BRAUS_PHASES
            let confirming = PhaseInterval.begin("capture.freshStill")
            #endif
            let fresh = try? await freshStill(target)
            #if BRAUS_PHASES
            confirming.end()
            #endif
            if let fresh, fresh.showsSameContent(as: kept.frame) {
                #if BRAUS_PHASES
                reusing.end()
                #endif
                await MainActor.run {
                    target.lastSceneImage = image
                    lastScene.kept = LastScene.Kept(frame: fresh, window: window, capture: kept.capture)
                }
                return perceived(kept.capture)
            }
            // The fresh pixels are read only at the observed rectangle, which the next Command maps through.
            if let fresh, fresh.geometry.screenRect == frame, let pixels = fresh.makeCGImage() {
                image      = pixels
                comparable = fresh
            }
        }
        #if BRAUS_PHASES
        let perceiving = PhaseInterval.begin("pipeline")
        #endif
        let capture = try await pipeline.capture(image, of: window)
        #if BRAUS_PHASES
        perceiving.end()
        #endif
        await MainActor.run {
            target.lastSceneImage = image
            if let comparable { lastScene.kept = LastScene.Kept(frame: comparable, window: window, capture: capture) }
        }
        return perceived(capture)
    }

    /// Whether a kept scene may answer a still whose pixels equal its frame's, from the uptime
    /// instants its frame was displayed at and the last Command went out at. With no Command yet
    /// equal pixels are enough; after one, only a frame displayed after it is, never an unknown time.
    package static func mayReuse(keptDisplayedAt: UInt64?, lastCommandAt: UInt64?) -> Bool {
        guard let lastCommandAt else { return true }
        guard let keptDisplayedAt else { return false }
        return keptDisplayedAt > lastCommandAt
    }

    /// LastScene keeps the window still the last scene was built from, with the window facts and the
    /// scene, so the next still can be compared to it. Only the latest is kept, and replacing it
    /// releases the Frame, which owns its surface (a stopped Still's, or a detached copy).
    @MainActor
    private final class LastScene {

        struct Kept: Sendable {
            let frame  : SeatFrame
            let window : ScenePipeline.Window
            let capture: SceneCapture
        }

        var kept: Kept?
    }
}

/// ApplicationIdentity is the bundle id and name a scene is stamped with, asked for by process id
/// through a closure supplied at composition, so this module never imports AppKit.
public struct ApplicationIdentity: Sendable, Equatable {

    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name     = name
    }
}
