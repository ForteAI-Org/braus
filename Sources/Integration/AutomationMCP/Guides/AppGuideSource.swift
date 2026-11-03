import Foundation

/// AppGuideSource supplies profile-selected files. Loading runs outside the main actor.
public nonisolated protocol AppGuideSource: Sendable {
    func guides() throws -> [AppGuide]
}

/// GuideFiles reads only the URLs explicitly supplied by the composition.
public nonisolated struct GuideFiles: AppGuideSource {
    private let urls: [URL]

    public init(urls: [URL]) { self.urls = urls }

    public func guides() throws -> [AppGuide] {
        try urls.map { url in
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw AppGuide.ParseError.invalidUTF8 }
            return try AppGuide.parse(text)
        }
    }
}
