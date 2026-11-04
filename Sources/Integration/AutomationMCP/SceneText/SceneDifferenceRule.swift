/// SceneDifferenceRule bounds each scene's dependency chain to an anchor and at most two differences.
/// A difference is retained only when its complete text is at most 75 percent of the whole scene.
nonisolated public enum SceneDifferenceRule {
    static func choose(
        baselines: SceneWindowBaselines,
        wholeCharacters: Int,
        changes: (Int) -> Int
    ) -> SceneAnswer.Form {
        let base: SceneAnswer.Base = baselines.lastBase == .anchor ? .last : .anchor
        let revision = base == .anchor ? baselines.anchor.revision : baselines.last.revision
        let count = changes(revision)
        return count * 4 <= wholeCharacters * 3
            ? .changes(since: revision, base: base) : .whole(because: nil)
    }
}
