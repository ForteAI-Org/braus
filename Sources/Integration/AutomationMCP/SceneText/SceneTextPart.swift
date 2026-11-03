import PerceptionCore

/// SceneTextPart identifies the source and role of a contiguous UTF-8 span of a scene answer.
nonisolated public struct SceneTextPart: Sendable, Equatable {
    public typealias Source = SceneSnapshot.TextLine.Source
    public typealias Job = SceneSnapshot.TextLine.Job
    public let source: Source
    public let job: Job
    public let utf8: Range<Int>
    public let section: String?
}
