/// SceneContextReset names why the model's context no longer holds earlier scenes.
nonisolated public enum SceneContextReset: String, Sendable, Equatable, CaseIterable {
    case compaction, newSession, sessionSwitch, personHadApp
}
