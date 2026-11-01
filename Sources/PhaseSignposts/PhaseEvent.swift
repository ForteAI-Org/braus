#if BRAUS_PHASES
/// PhaseEvent emits typed point measurements independently of the scene pipeline.
public enum PhaseEvent {
    package struct SceneStage: Sendable, Equatable {
        package let stage: String
        package let duration: Duration
    }

    @TaskLocal
    package static var sceneObserver: (@Sendable (SceneStage) -> Void)?

    /// Emits the duration supplied by the existing scene timing hook.
    public static func sceneStage<Stage: RawRepresentable>(_ stage: Stage, _ duration: Duration)
    where Stage.RawValue == String {
        sceneObserver?(SceneStage(stage: stage.rawValue, duration: duration))
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        PhaseInterval.event("scene.stage", "stage=\(stage.rawValue) duration_seconds=\(seconds)")
    }
}
#endif
