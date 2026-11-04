import AutomationRuntime
import Capabilities
import Foundation

/// AppGuides selects compatible guides and complete, uncovered sections within the caller's remaining budget.
/// Loading and index construction finish before publication; the main actor retains only prepared values.
@MainActor
public final class AppGuides {
    public nonisolated enum LoadError: Error, Sendable, Equatable {
        case conflictingGuide
        case headExceedsCeiling
    }

    private let guides: [AppGuide]
    private let search: GuideSearch
    private let tokenCeiling: @Sendable (String) -> Int
    private let estimateTokens: @Sendable (String) -> Int
    private let similarity: @Sendable (String, String) async -> Double
    private let coverThreshold: Double

    /// Retains already validated guides and prepared search indices; performs no I/O or index construction.
    public init(
        guides: [AppGuide],
        search: GuideSearch,
        tokenCeiling: @escaping @Sendable (String) -> Int = { _ in 1500 },
        estimateTokens: @escaping @Sendable (String) -> Int,
        coverThreshold: Double = 0.85,
        similarity: @escaping @Sendable (String, String) async -> Double
    ) {
        self.guides = guides
        self.search = search
        self.tokenCeiling = tokenCeiling
        self.estimateTokens = estimateTokens
        self.coverThreshold = coverThreshold
        self.similarity = similarity
    }

    /// Reads sources and prepares indices on the concurrent executor, publishing only a complete instance.
    /// EB2 composition supplies TokenEstimate.tokens(in:), using (text.count + 3) / 4.
    @concurrent
    public static func load(
        sources: [any AppGuideSource],
        search: GuideSearch? = nil,
        vectors: CatalogueVectors? = nil,
        embedding: (any TextEmbedding)? = nil,
        tokenCeiling: @escaping @Sendable (String) -> Int = { _ in 1500 },
        estimateTokens: @escaping @Sendable (String) -> Int,
        coverThreshold: Double = 0.85,
        similarity: @escaping @Sendable (String, String) async -> Double
    ) async throws -> AppGuides {
        let guides = try sources.flatMap { try $0.guides() }
        for (index, guide) in guides.enumerated() {
            guard estimateTokens(guide.head) <= tokenCeiling(guide.header.app) else { throw LoadError.headExceedsCeiling }
            for other in guides.prefix(index) where sameIdentity(guide, other) && guide != other {
                throw LoadError.conflictingGuide
            }
        }
        let prepared = search ?? GuideSearch(guides: guides, vectors: vectors, embedding: embedding)
        return await AppGuides(guides: guides, search: prepared, tokenCeiling: tokenCeiling,
            estimateTokens: estimateTokens, coverThreshold: coverThreshold, similarity: similarity)
    }

    public func head(for app: OpenedApp) -> GuideHead? {
        guard let guide = guide(for: app) else { return nil }
        return GuideHead(header: guide.header, text: guide.head)
    }

    /// Uses memory text from the same app, then spends only the budget left after the head and memory.
    public func sections(
        for app: OpenedApp,
        todo: [String],
        budgetTokens: Int,
        coveredBy memory: [MemoryPartSummary]
    ) async -> GuideSelection {
        guard let guide = guide(for: app) else {
            return GuideSelection(sections: [], overlaps: [])
        }
        let candidates = await search.sections(for: guide, query: todo.joined(separator: "\n"))
        return await select(candidates, guide: guide, budgetTokens: budgetTokens, memory: memory)
    }

    /// Records only content retained by the delivery budget, within the dispatcher's current call.
    func noteDelivered(for app: OpenedApp, sections: [String], head: Bool = true) {
        guard let call = CallDispatcher.taskStateCall, let guide = guide(for: app) else { return }
        let id = search.identifier(for: guide)
        for section in (head ? ["head"] : []) + sections {
            call.loaded.append(.guide(id: id, section: section))
        }
    }

    private func select(_ candidates: [AppGuide.Section], guide: AppGuide, budgetTokens: Int,
                        memory: [MemoryPartSummary]) async -> GuideSelection {
        var remaining = max(0, min(budgetTokens, tokenCeiling(guide.header.app) - estimateTokens(guide.head)))
        var sections: [AppGuide.Section] = []
        var overlaps: [GuideOverlap] = []
        var leftOut = 0
        for section in candidates {
            guard sections.count < 3 else { break }
            var covered = false
            for part in memory where part.bundleID == guide.header.app {
                let score = await similarity(section.text, part.text)
                if score.isFinite, score >= coverThreshold {
                    overlaps.append(GuideOverlap(section: section.title, memoryPartID: part.partID,
                        similarity: score, contrast: .unknown))
                    covered = true
                    break
                }
            }
            guard !covered else { continue }
            let cost = max(0, estimateTokens(section.text))
            if cost <= remaining { sections.append(section); remaining -= cost }
            else { leftOut += 1 }
        }
        return GuideSelection(sections: sections, overlaps: overlaps, leftOut: leftOut)
    }

    private func guide(for app: OpenedApp) -> AppGuide? {
        let locale = app.locale.replacingOccurrences(of: "_", with: "-").lowercased()
        let language = locale.split(separator: "-").first.map(String.init) ?? locale
        return guides.filter { guide in
            guard guide.header.app == app.bundleID else { return false }
            let candidate = guide.header.locale.lowercased()
            guard candidate == locale || candidate == language
                || (locale == language && candidate.split(separator: "-").first.map(String.init) == language)
            else { return false }
            if let range = guide.header.appVersions {
                guard let version = app.version else { return false }
                return range.minimum <= version && version <= range.maximum
            }
            return true
        }.sorted { left, right in
            let a = left.header.locale.lowercased() == locale
            let b = right.header.locale.lowercased() == locale
            if a != b { return a }
            if left.header.revision != right.header.revision { return left.header.revision > right.header.revision }
            return search.identifier(for: left) < search.identifier(for: right)
        }.first
    }

    private nonisolated static func sameIdentity(_ lhs: AppGuide, _ rhs: AppGuide) -> Bool {
        lhs.header.app == rhs.header.app && lhs.header.locale.lowercased() == rhs.header.locale.lowercased()
            && lhs.header.appVersions == rhs.header.appVersions && lhs.header.revision == rhs.header.revision
    }
}
