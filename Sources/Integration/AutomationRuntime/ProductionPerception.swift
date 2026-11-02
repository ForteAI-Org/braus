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

    /// Creates a fresh pipeline with local OCR, icon and media geometry, panels and native facts.
    /// Text-only mode keeps OCR and native facts, without segmentation, media filtering or panels.
    /// `valueGuard` opts into secure and reserved native value filtering; worker pipelines leave it nil.
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
    public static func foregroundScenes(excludingProcesses: [pid_t] = []) -> any SceneProviding {
        LiveSceneProvider(
            pipeline: pipeline(),
            windows: WindowServerWindowListing(),
            capturer: StillCapturer(excludingProcesses: excludingProcesses),
            identity: { RunningApplicationLookup.identity(of: $0) }
        )
    }
}
