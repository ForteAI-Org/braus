import Capabilities
import CryptoKit
import Foundation

/// GuideSearch retains immutable, separate document indices for each guide's complete content.
/// The composition supplies a snapshot of the shared vector store and the existing embedding adapter.
public nonisolated struct GuideSearch: Sendable {
    private struct Index: Sendable {
        let search: DocumentSearch
        let sections: [String: AppGuide.Section]
        let identifier: String
    }

    private let indices: [AppGuide: Index]

    public init(guides: [AppGuide], vectors: CatalogueVectors? = nil, embedding: (any TextEmbedding)? = nil) {
        indices = Dictionary(guides.map { guide in
            let documents = Self.documents(for: guide)
            return (guide, Index(
                search: DocumentSearch(documents: documents, vectors: vectors, embedding: embedding),
                sections: Dictionary(uniqueKeysWithValues: zip(documents.map(\.id), guide.sections)),
                identifier: Self.identifier(guide)))
        }, uniquingKeysWith: { first, _ in first })
    }

    public static func documents(for guide: AppGuide) -> [SearchDocument] {
        let digest = identifier(guide)
        return guide.sections.enumerated().map {
            SearchDocument(id: digest + ":" + String($0.offset), text: $0.element.text)
        }
    }

    func identifier(for guide: AppGuide) -> String { indices[guide]?.identifier ?? "" }

    private static func identifier(_ guide: AppGuide) -> String {
        let identity = [guide.header.app, guide.header.locale, String(guide.header.revision),
                        guide.header.name, guide.header.description,
                        guide.header.appVersions?.minimum.components.description ?? "",
                        guide.header.appVersions?.maximum.components.description ?? "", guide.head]
            + guide.sections.flatMap { [$0.title, $0.body] }
        return SHA256.hash(data: Data(identity.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    @concurrent
    public func sections(for guide: AppGuide, query: String) async -> [AppGuide.Section] {
        guard let index = indices[guide] else { return [] }
        return await index.search.search(query, limit: Int.max).compactMap { index.sections[$0.id] }
    }
}
