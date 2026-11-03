import Perception
import Synchronization
import Testing
@testable import PhaseSignposts

struct PhaseEventTests {
    @Test func sceneStageFromTimingHook() {
        let logged = Mutex<[String]>([])
        let hook: ScenePipeline.TimingHook = { stage, duration in
            #if BRAUS_PHASES
            PhaseEvent.sceneStage(stage, duration)
            #endif
            logged.withLock { $0.append("scene phase \(stage.rawValue): \(duration.description)") }
        }
        let stages: [ScenePipeline.Stage] = [.ocr, .augmentation, .merge]
        #if BRAUS_PHASES
        let events = Mutex<[PhaseEvent.SceneStage]>([])
        PhaseEvent.$sceneObserver.withValue({ event in events.withLock { $0.append(event) } }) {
            for stage in stages { hook(stage, .milliseconds(3)) }
        }
        #expect(events.withLock { $0.map(\.stage) } == stages.map(\.rawValue))
        #expect(events.withLock { $0.allSatisfy { $0.duration == .milliseconds(3) } })
        #else
        for stage in stages { hook(stage, .milliseconds(3)) }
        #endif
        #expect(logged.withLock { $0 } == stages.map { "scene phase \($0.rawValue): \(Duration.milliseconds(3).description)" })
    }
}
