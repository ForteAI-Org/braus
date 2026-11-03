/// SceneDifferenceRule selects the last reading under half the whole, or alternates anchor/last up to 75 percent.
nonisolated public enum SceneDifferenceRule: String, Sendable {
    case chained, hybrid75

    func choose(
        baselines: SceneWindowBaselines,
        wholeCharacters: Int,
        changes: (Int) -> Int
    ) -> SceneAnswer.Form {
        let base: SceneAnswer.Base = self == .chained ? .last
            : baselines.lastBase == .anchor ? .last : .anchor
        let revision = base == .anchor ? baselines.anchor.revision : baselines.last.revision
        let count = changes(revision)
        let fits = self == .chained ? count * 2 < wholeCharacters : count * 4 <= wholeCharacters * 3
        return fits ? .changes(since: revision, base: base) : .whole(because: nil)
    }
}
