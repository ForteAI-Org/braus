import AccessibilityFacts
import EngineCore
import Foundation
import LiveScenes
import Perception
import PixelSections
import PixelRegions
import ScreenCapture
import VisionText
import WindowPlacement
import WindowServerListing

/// ProductionPerception composes the same observation adapters for actions and visual inspection.
/// It creates no memory store, actuator, provider connection, or background seat.
public enum ProductionPerception {

    /// Mode selects whether pixels contribute geometry beyond recognized text.
    public enum Mode: String, Sendable {
        case full
        case textOnly = "text-only"
    }

    /// The worker's value guard: the role rule only. No label is reserved, so a field named "Key" or "Token"
    /// stays readable; the full predicate is SG3's classifier.
    package nonisolated static let workerValueGuard: @Sendable (String) -> Bool = { _ in false }

    /// Creates the production pipeline with the worker's role-only value guard.
    package nonisolated static func workerPipeline(
        mode: Mode = .full,
        timingHook: ScenePipeline.TimingHook? = nil
    ) -> ScenePipeline {
        pipeline(mode: mode, valueGuard: workerValueGuard, timingHook: timingHook)
    }

    /// Creates a fresh pipeline with local OCR, icon and media geometry, panels and native facts.
    /// Text-only mode keeps OCR and native facts, without segmentation, media filtering or panels.
    /// `valueGuard` opts into secure and reserved native value filtering.
    /// `timingHook` observes construction and stage durations. Nil keeps timing disabled.
    public nonisolated static func pipeline(
        mode: Mode = .full,
        valueGuard: (@Sendable (String) -> Bool)? = nil,
        timingHook: ScenePipeline.TimingHook? = nil
    ) -> ScenePipeline {
        let started = timingHook.map { _ in ContinuousClock.now }
        defer { if let started { timingHook?(.pipelineInitialization, started.duration(to: .now)) } }
        let text = VisionTextRecognizer()
        if let started { timingHook?(.visionInitialization, started.duration(to: .now)) }
        return ScenePipeline(text: text, regions: mode == .full ? ConnectedComponentSegmenter() : nil,
                      regionFilter: mode == .full ? MediaRegionFilter() : nil,
                      sections: mode == .full ? ColorSectionDetector() : nil,
                      augmentation: AccessibilityAugmenter(
                          windowNumberResolver: { WindowRelocator.windowNumber(of: $0) },
                          valueGuard: valueGuard
                      ), timingHook: timingHook)
    }

    /// Creates a foreground reader. Excluded processes remain absent from popup-region captures,
    /// allowing an inspection overlay to observe without reading its own rendered boxes.
    /// Workers pass `workerValueGuard`; Peek and Watch inspect the person's screen without a guard.
    /// The person's scene reader supplies its own label predicate, independently of worker policy.
    public static func foregroundScenes(
        excludingProcesses: [pid_t] = [],
        valueGuard: (@Sendable (String) -> Bool)? = nil
    ) -> any SceneProviding {
        LiveSceneProvider(
            pipeline: pipeline(valueGuard: valueGuard),
            windows: WindowServerWindowListing(),
            capturer: StillCapturer(excludingProcesses: excludingProcesses),
            identity: { RunningApplicationLookup.identity(of: $0) }
        )
    }
}
