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
/// Byte-identical pixels of the same window reuse recognition and grouping (ADR 0034).
/// Native values, roles and read quality are refreshed on every observation: a control can change
/// without drawing, including when its track is outside the visible viewport. After a Command,
/// the existing fresh-still check still prevents an old stream frame from proving equal pixels.
/// Display crops are always recognized again.
public struct SeatSceneProvider: SceneProviding {

    private let target: SeatTarget
    private let pipeline: ScenePipeline
    private let windows: any WindowListing
    private let identity: @Sendable (pid_t) -> ApplicationIdentity?
    private let freshStill: @MainActor @Sendable (SeatTarget) async throws -> SeatFrame
    private let displayBounds: @MainActor @Sendable (SeatTarget) -> CGRect
    private let displayStill: @MainActor @Sendable (SeatTarget) async throws -> SeatFrame
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
    /// can answer it without ScreenCaptureKit. Display bounds and stills can likewise be supplied
    /// for a popup crop without starting a host.
    package init(
        target    : SeatTarget,
        pipeline  : ScenePipeline,
        windows   : any WindowListing,
        identity  : @escaping @Sendable (pid_t) -> ApplicationIdentity?,
        freshStill: @escaping @MainActor @Sendable (SeatTarget) async throws -> SeatFrame,
        displayBounds: @escaping @MainActor @Sendable (SeatTarget) -> CGRect = {
            $0.displayID.map(CGDisplayBounds) ?? .null
        },
        displayStill: @escaping @MainActor @Sendable (SeatTarget) async throws -> SeatFrame = {
            try await $0.displayStill()
        }
    ) {
        self.target     = target
        self.pipeline   = pipeline
        self.windows    = windows
        self.identity   = identity
        self.freshStill = freshStill
        self.displayBounds = displayBounds
        self.displayStill = displayStill
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
        let seatBounds = await displayBounds(target)
        let onSeat = try await windows.windows(ownedBy: processID).filter { $0.frame.intersects(seatBounds) }
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
            let displayCapture = PhaseInterval.begin("capture.displayStill")
            #endif
            let still = try await displayStill(target)
            #if BRAUS_PHASES
            displayCapture.end()
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
            guard await target.isCurrentObservation(observation.reference) else {
                throw SeatDrivingFailure.frameUnusable
            }
        }
        // Adoption keeps a recovery title; only a fresh census can name the document now displayed.
        let matchingRows = try await windows.windows(ownedBy: processID).filter { $0.number == observedWindow.id }
        let currentTitle = matchingRows.count == 1 ? matchingRows[0].title ?? "" : ""
        let window = ScenePipeline.Window(
            bundleID    : application.bundleID,
            appName     : application.name,
            title       : currentTitle,
            processID   : processID,
            frame       : frame,
            windowNumber: observedWindow.id,
            occludingFrames: popups
        )
        // The union with an open pop-up is two windows in one picture, not a structural surface.
        func perceived(_ capture: SceneCapture) -> PerceivedWindow {
            let surface = popups.isEmpty
                ? CaptureSurface.classified(role: capture.quality.windowRole, subrole: capture.quality.windowSubrole)
                : CaptureSurface.popupUnion
            return PerceivedWindow(scene: capture.scene, frame: frame, capture: capture.quality, surface: surface)
        }
        // Equal pixels can reuse recognition, never the native facts merged into the previous scene.
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
                return perceived(try await pipeline.capture(image, of: window, reusing: kept.visual).capture)
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
                    lastScene.kept = LastScene.Kept(frame: fresh, window: window, visual: kept.visual)
                }
                return perceived(try await pipeline.capture(image, of: window, reusing: kept.visual).capture)
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
        let reading = try await pipeline.capture(image, of: window, reusing: nil)
        #if BRAUS_PHASES
        perceiving.end()
        #endif
        await MainActor.run {
            target.lastSceneImage = image
            if let comparable { lastScene.kept = LastScene.Kept(frame: comparable, window: window, visual: reading.visual) }
        }
        return perceived(reading.capture)
    }

    /// Whether a kept scene may answer a still whose pixels equal its frame's, from the uptime
    /// instants its frame was displayed at and the last Command went out at. With no Command yet
    /// equal pixels are enough; after one, only a frame displayed after it is, never an unknown time.
    package static func mayReuse(keptDisplayedAt: UInt64?, lastCommandAt: UInt64?) -> Bool {
        guard let lastCommandAt else { return true }
        guard let keptDisplayedAt else { return false }
        return keptDisplayedAt > lastCommandAt
    }

    /// LastScene keeps the window still with its window facts and pixel-derived scene, so the next
    /// still can reuse recognition. Only the latest is kept, and replacing it
    /// releases the Frame, which owns its surface (a stopped Still's, or a detached copy).
    @MainActor
    private final class LastScene {

        struct Kept: Sendable {
            let frame  : SeatFrame
            let window : ScenePipeline.Window
            let visual : ScenePipeline.VisualScene
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
