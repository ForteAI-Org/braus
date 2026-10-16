import CoreGraphics
import Dispatch
import Foundation
import Perception
import PerceptionCore
import Synchronization
import Testing

@Suite("Perception scheduling")
struct ScenePipelineConcurrencyTests {
    private final class OverlapProbe: Sendable {
        let nativeStarted = DispatchSemaphore(value: 0)
        let overlapped = Mutex(false)
    }

    private struct WaitingText: TextRecognizing {
        let probe: OverlapProbe
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            let result = probe.nativeStarted.wait(timeout: .now() + 2) == .success
            probe.overlapped.withLock { $0 = result }
            return []
        }
    }

    private final class AbandonProbe: Sendable {
        let started = DispatchSemaphore(value: 0)
        let abandoned = DispatchSemaphore(value: 0)

        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 5) == .success }
    }

    /// A read that runs until it is abandoned, or for five seconds: the synchronous read cannot be
    /// abandoned, the cancellable one is abandoned when its task is cancelled.
    private struct AbandonableText: TextRecognizing {
        let probe: AbandonProbe
        let blockedImageWidth: Int

        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            guard image.width == blockedImageWidth else { return [] }
            probe.started.signal()
            _ = probe.abandoned.wait(timeout: .now() + 5)
            return []
        }
        func recognizeTextCancellably(in image: CGImage, accuracy: TextRecognitionAccuracy) async throws -> [RecognizedText] {
            try await withTaskCancellationHandler {
                _ = try recognizeText(in: image, accuracy: accuracy)
                try Task.checkCancellation()
                return []
            } onCancel: {
                probe.abandoned.signal()
            }
        }
    }

    private struct SignalingNative: SceneAugmenting {
        let probe: OverlapProbe
        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest {
            probe.nativeStarted.signal()
            return .none
        }
    }

    private struct ThreadCheckingSections: SectionDetecting {
        func sections(in image: CGImage, protecting text: [CGRect]) throws -> [CGRect] {
            #expect(!Thread.isMainThread, "pixel scans must not freeze the overlay/input run loop")
            return []
        }
    }

    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func nativeReadStartsWhileOCRIsStillRunning() async throws {
        let probe = OverlapProbe()
        let pipeline = ScenePipeline(text: WaitingText(probe: probe), augmentation: SignalingNative(probe: probe))
        _ = try await pipeline.perceive(image(), of: .init(bundleID: "test", appName: "Test", title: "",
            processID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(probe.overlapped.withLock { $0 })
    }

    @Test @MainActor func mainActorCallerDoesNotRunPixelAnalysisOnMainThread() async throws {
        let pipeline = ScenePipeline(text: ScenePipelineTests.FixedText(runs: []), sections: ThreadCheckingSections())
        _ = try await pipeline.perceive(image(), of: .init(bundleID: "test", appName: "Test", title: ""))
    }

    @Test func cancelledObservationDoesNotStartRecognition() async throws {
        let capture = try image()
        let pipeline = ScenePipeline(text: ScenePipelineTests.FixedText(runs: [], failure: ScenePipelineTests.Unavailable()))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.perceive(capture, of: .init(bundleID: "test", appName: "Test", title: ""))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [false, true])
    func cancelledObservationAbandonsRecognitionInProgress(inPopup: Bool) async throws {
        let probe = AbandonProbe()
        let capture = try image()
        let popup = CGRect(x: 10, y: 10, width: 40, height: 30)
        let pipeline = ScenePipeline(text: AbandonableText(probe: probe, blockedImageWidth: inPopup ? 40 : 100))
        let window = ScenePipeline.Window(
            bundleID: "test", appName: "Test", title: "",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            occludingFrames: inPopup ? [popup] : []
        )
        let task = Task {
            try await pipeline.perceive(capture, of: window)
        }
        let started = await Task.detached { probe.waitUntilStarted() }.value
        #expect(started)
        let clock = ContinuousClock(), cancelled = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - cancelled < .seconds(1), "a stop does not wait for the rest of the read")
    }
}
