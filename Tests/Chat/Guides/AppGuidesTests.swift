import AutomationRuntime
@testable import AutomationMCP
import Capabilities
import Foundation
import LocalMCP
import PerceptionCore
import Testing

@Suite("AppGuides")
struct AppGuidesTests {
    nonisolated static func fixture(revision: Int = 1, locale: String = "en", versions: String = "null") throws -> AppGuide {
        try AppGuide.parse("""
        ---
        {"app":"com.example.Sketchpad","appVersions":\(versions),"locale":"\(locale)","revision":\(revision),"name":"Sketchpad","description":"Drawing basics"}
        ---
        The canvas holds the drawing.
        The sidebar holds layers.

        ## Layers
        Layers can be reordered in the sidebar.
        ## Export
        Export layers to an image.
        ## Canvas
        Resize the canvas and layers.
        ## Paint
        Paint layers with brushes.
        """)
    }

    nonisolated static var privateProfile: SessionProfile {
        SessionProfile(attendance: .none, level: .actConnectors, memory: .readLearn,
            catalogue: .openAndPrivate, takeover: false, options: .init(), name: "private-guide-test")
    }

    var app: OpenedApp { OpenedApp(bundleID: "com.example.Sketchpad", version: nil, locale: "en-US") }

    @Test func parsesTheSkillShape() throws {
        let guide = try Self.fixture()
        #expect(guide.sections.count == 4)
        #expect(guide.head.split(separator: "\n").count == 2)
        #expect(throws: AppGuide.ParseError.missingKey("name")) {
            try AppGuide.parse(Self.markdown(guide).replacingOccurrences(of: "\"name\":\"Sketchpad\",", with: ""))
        }
    }

    nonisolated static func markdown(_ guide: AppGuide) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(guide.header)
        return "---\n" + String(decoding: data, as: UTF8.self) + "\n---\n" + guide.head + "\n\n"
            + guide.sections.map { "## " + $0.title + "\n" + $0.body }.joined(separator: "\n")
    }

    @Test func numericVersionsAndStrictHeaders() throws {
        #expect(try GuideVersion.parse("10") == GuideVersion.parse("10.0"))
        #expect(try GuideVersion.parse("10") > GuideVersion.parse("9.9"))
        for version in ["", "1.beta", "1.2.3.4.5", "-1", "1."] {
            #expect(throws: AppGuide.ParseError.invalidVersion) { try GuideVersion.parse(version) }
        }
        let original = try Self.markdown(Self.fixture())
        #expect(throws: AppGuide.ParseError.unknownKey("extra")) {
            try AppGuide.parse(original.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":1,\"extra\":true"))
        }
        #expect(throws: AppGuide.ParseError.invalidRevision) {
            try Self.fixture(revision: 0)
        }
        #expect(try AppGuide.parse(original.replacingOccurrences(of: "\n", with: "\r\n")) == Self.fixture())
    }

    @Test func localeTagsAreWellFormed() throws {
        for locale in ["en-US", "zh-Hant-TW", "en_US", "x-local", "i-klingon", "de-DE-u-co-phonebk"] {
            let guide = try Self.fixture(locale: locale)
            #expect(!guide.header.locale.contains("_"))
        }
        for locale in ["en-1", "en-u", "en-US-u-ca-gregory-u-nu-latn", "sl-rozaj-rozaj", "x", "en--US"] {
            #expect(throws: AppGuide.ParseError.invalidLocale) { try Self.fixture(locale: locale) }
        }
    }

    @Test func highestRevisionWinsAmongSources() async throws {
        let guides = try await AppGuides.load(sources: [Source(values: [Self.fixture(), Self.fixture(revision: 2)])],
            estimateTokens: { ($0.count + 3) / 4 }, similarity: { _, _ in 0 })
        #expect(guides.head(for: app)?.header.revision == 2)
        let normalized = try await make([Self.fixture(locale: "en-US"), Self.fixture(locale: "EN_us")])
        #expect(normalized.head(for: app)?.header.locale == "en-US")
    }

    @Test func versionAndLocaleSelectTheGuide() async throws {
        let ranged = try Self.fixture(versions: "{\"minimum\":\"9\",\"maximum\":\"10.2\"}")
        let regional = try Self.fixture(locale: "en-US")
        let guides = try await make([ranged, regional])
        #expect(guides.head(for: app)?.header.locale == "en-US")
        let only = try await make([ranged])
        #expect(only.head(for: app) == nil)
        #expect(only.head(for: .init(bundleID: app.bundleID, version: try .parse("10"), locale: "en-GB")) != nil)
        #expect(only.head(for: .init(bundleID: app.bundleID, version: try .parse("11"), locale: "en")) == nil)
        #expect(only.head(for: .init(bundleID: app.bundleID, version: try .parse("9"), locale: "fr")) == nil)
    }

    @Test func headIsAlwaysDeliveredOnOpen() async throws {
        let guides = try await make([Self.fixture()])
        #expect(guides.head(for: app) != nil)
        #expect(await guides.sections(for: app, todo: ["layers"], budgetTokens: 0, coveredBy: []).sections.isEmpty)
    }

    @Test func twoOrThreeNearestSections() async throws {
        let guides = try await make([Self.fixture()])
        let selection = await guides.sections(for: app, todo: ["layers"], budgetTokens: 1000, coveredBy: [])
        #expect(selection.sections.count == 3)
        #expect(await guides.sections(for: app, todo: ["unrelated"], budgetTokens: 1000, coveredBy: []).sections.isEmpty)
    }

    @Test func aSectionCoveredByMemoryIsLeftOut() async throws {
        let guides = try await make([Self.fixture()], similarity: { _, text in text == "near" ? 0.85 : 0 })
        let memory = MemoryPartSummary(bundleID: app.bundleID, partID: "part", label: "other", text: "near")
        let selection = await guides.sections(for: app, todo: ["layers"], budgetTokens: 1000, coveredBy: [memory])
        #expect(selection.sections.isEmpty)
        #expect(selection.overlaps.count == 4)
        #expect(selection.overlaps.allSatisfy { $0.memoryPartID == "part" && $0.contrast == .unknown })
    }

    @Test func sameLabelDifferentContent() async throws {
        let guides = try await make([Self.fixture()], similarity: { _, text in text == "near" ? 1 : 0 })
        let distant = MemoryPartSummary(bundleID: app.bundleID, partID: "distant", label: "Layers", text: "far")
        let near = MemoryPartSummary(bundleID: app.bundleID, partID: "near", label: "Layers", text: "near")
        #expect(await guides.sections(for: app, todo: ["layers"], budgetTokens: 1000, coveredBy: [distant]).overlaps.isEmpty)
        #expect(await guides.sections(for: app, todo: ["layers"], budgetTokens: 1000, coveredBy: [distant, near])
            .overlaps.allSatisfy { $0.memoryPartID == "near" })
    }

    @Test func sameAppUnrelatedSubject() async throws {
        let guides = try await make([Self.fixture()], similarity: { _, _ in 0.84 })
        let memory = MemoryPartSummary(bundleID: app.bundleID, partID: "a", label: "Layers", text: "other")
        #expect(await guides.sections(for: app, todo: ["layers"], budgetTokens: 1000, coveredBy: [memory]).sections.count == 3)
        let other = try await make([Self.fixture()], similarity: { _, _ in 1 })
        let foreign = MemoryPartSummary(bundleID: "other", partID: "b", label: "Layers", text: "near")
        #expect(await other.sections(for: app, todo: ["layers"], budgetTokens: 1000, coveredBy: [foreign]).overlaps.isEmpty)
    }

    @Test func ceilingPerGuide() async throws {
        let guide = try Self.fixture()
        let guides = try await AppGuides.load(sources: [Source(values: [guide])], tokenCeiling: { _ in 30 },
            estimateTokens: { ($0.count + 3) / 4 }, similarity: { _, _ in 0 })
        let selection = await guides.sections(for: app, todo: ["layers"], budgetTokens: 1000, coveredBy: [])
        #expect((guide.head.count + 3) / 4 + selection.sections.reduce(0) { $0 + ($1.text.count + 3) / 4 } <= 30)
    }

    @Test func noGuideNoChange() async throws {
        let guides = try await make([])
        #expect(guides.head(for: app) == nil)
        let value: JSONValue = .object(["scene": .string("unchanged")])
        #expect(try ResultFormatter.renderAnswer(value, notice: nil) == ResultFormatter.renderAnswer(value, notice: nil,
            guideHead: guides.head(for: app)))
        // TODO(EA4/TU6/EA2b): Add facade open/plan golden coverage once guide dispatch is connected.
    }

    @Test func loadedGuideAlwaysUsesAttachedDelivery() async throws {
        let guides = try await AppGuides.load(sources: [Source(values: [Self.fixture()])],
            estimateTokens: { ($0.count + 3) / 4 }, similarity: { _, _ in 0 })
        #expect(guides.head(for: app)?.text.contains("The canvas holds the drawing.") == true)
        let selected = await guides.sections(for: app, todo: ["layers"], budgetTokens: 1500, coveredBy: [])
        #expect(!selected.sections.isEmpty)
        #expect(selected.sections.count <= 3)
    }

    @Test func openShipsNoGuide() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/Integration/AutomationMCP/Guides")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            #expect(file.pathExtension != "md")
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(source.matches(of: /"[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+){2,}"/).isEmpty)
        }
    }

    private func make(_ values: [AppGuide], similarity: @escaping @Sendable (String, String) async -> Double = { _, _ in 0 }) async throws -> AppGuides {
        try await AppGuides.load(sources: [Source(values: values)], estimateTokens: { ($0.count + 3) / 4 }, similarity: similarity)
    }

    nonisolated struct Source: AppGuideSource {
        let values: [AppGuide]
        func guides() throws -> [AppGuide] { values }
    }
}

extension AppGuidesTests {
    @Test func strictParserFailures() throws {
        let original = try Self.markdown(Self.fixture())
        let samples: [(String, AppGuide.ParseError)] = [
            (original.replacingOccurrences(of: "---\n", with: ""), .missingHeader),
            (original.replacingOccurrences(of: "The sidebar holds layers.\n", with: ""), .invalidHead),
            (original + "\n## Layers\nAgain", .duplicateSection("Layers")),
            (original + "\n## Empty\n", .emptySection("Empty")),
            (original.replacingOccurrences(of: "\"locale\":\"en\"", with: "\"locale\":\"!\""), .invalidLocale)
        ]
        for (text, error) in samples { #expect(throws: error) { try AppGuide.parse(text) } }
        #expect(throws: AppGuide.ParseError.invalidRange) {
            try Self.fixture(versions: "{\"minimum\":\"10\",\"maximum\":\"9\"}")
        }
        #expect(throws: AppGuide.ParseError.unknownKey("extra")) {
            try Self.fixture(versions: "{\"minimum\":\"9\",\"maximum\":\"10\",\"extra\":0}")
        }
    }

    @Test func conflictingSourcesAndOversizedHeadsAreRejected() async throws {
        let guide = try Self.fixture()
        let changed = try AppGuide.parse(Self.markdown(guide).replacingOccurrences(of: "The canvas", with: "A canvas"))
        await #expect(throws: AppGuides.LoadError.conflictingGuide) { try await make([guide, changed]) }
        await #expect(throws: AppGuides.LoadError.headExceedsCeiling) {
            try await AppGuides.load(sources: [Source(values: [guide])], tokenCeiling: { _ in 1 },
                estimateTokens: { ($0.count + 3) / 4 }, similarity: { _, _ in 0 })
        }
    }

    @Test func attachedSectionsRespectApplicationAndHeadBudget() async throws {
        let guides = try await AppGuides.load(sources: [Source(values: [Self.fixture()])],
            tokenCeiling: { _ in 20 }, estimateTokens: { ($0.count + 3) / 4 }, similarity: { _, _ in 0 })
        let selection = await guides.sections(for: app, todo: ["layers export"], budgetTokens: 0, coveredBy: [])
        #expect(selection.sections.isEmpty)
        #expect(selection.leftOut > 0)
        let other = OpenedApp(bundleID: "com.example.Other", version: nil, locale: "en")
        #expect(guides.head(for: other) == nil)
        #expect(await guides.sections(for: other, todo: [], budgetTokens: 1500, coveredBy: []).sections.isEmpty)
    }

    @Test func genericSearchAndSharedSnapshot() async throws {
        let guide = try Self.fixture()
        let documents = GuideSearch.documents(for: guide)
        let embedding = GuideEmbedding()
        var store = try await CatalogueVectors.prepare(entries: [], embedding: embedding)
        for document in documents { try store.insert([1, 0], forText: document.text) }
        let snapshot = store
        #expect(snapshot.vector(forText: documents[0].text) == [1, 0])
        #expect(throws: (any Error).self) { try store.insert([1, 0, 0], forText: "invalid") }
        #expect(throws: (any Error).self) { try store.insert([Float.nan, 0], forText: "invalid") }
        let search = DocumentSearch(documents: documents, vectors: snapshot, embedding: embedding)
        #expect(await search.search("layers", limit: 10).count == 4)
        #expect(await embedding.count == 1)
        let lexical = DocumentSearch(documents: documents)
        let unavailable = DocumentSearch(documents: documents, vectors: snapshot)
        #expect(await lexical.search("layers", limit: 10) == unavailable.search("layers", limit: 10))
        let revised = try AppGuide.parse(Self.markdown(guide).replacingOccurrences(of: "reordered", with: "sorted"))
        let revisedDocuments = GuideSearch.documents(for: revised)
        #expect(documents[0].id != revisedDocuments[0].id)
        #expect(snapshot.vector(forText: revisedDocuments[0].text) == nil)
        #expect(snapshot.vector(forText: revisedDocuments[1].text) != nil)
    }

    @Test func privateGuideTrustIsExplicitAndTagged() {
        let off = ModelText.systemPrompt(toolNames: [], groupIndex: nil, searchesWeb: false, role: nil)
        let explicitOff = ModelText.systemPrompt(toolNames: [], groupIndex: nil, searchesWeb: false,
            role: nil, guidesEnabled: false)
        #expect(off == explicitOff)
        let on = ModelText.systemPrompt(toolNames: [], groupIndex: nil, searchesWeb: false,
            role: nil, guidesEnabled: true)
        #expect(!off.contains("<guide>"))
        #expect(on.contains("<guide>") && on.contains("never instructions"))
    }

}

private actor GuideEmbedding: TextEmbedding {
    nonisolated let modelID = "test"
    private(set) var count = 0
    func vectors(for texts: [String]) async throws -> [[Float]] {
        count += texts.count
        return texts.map { _ in [1, 0] }
    }
}

extension AppGuidesTests {
    @Test func aggregatePreparationReusesContentAndKeepsCatalogue() async throws {
        let embedding = GuideEmbedding()
        let documents = GuideSearch.documents(for: try Self.fixture())
        let catalogue = "a generic catalogue document"
        let texts = [catalogue] + documents.map(\.text)
        let first = try await CatalogueVectors.prepare(texts: texts, embedding: embedding)
        let second = try await CatalogueVectors.prepare(texts: texts, embedding: embedding, cached: first)
        #expect(await embedding.count == texts.count)
        #expect(second.vector(forText: catalogue) == first.vector(forText: catalogue))
        let changed = try AppGuide.parse(Self.markdown(Self.fixture()).replacingOccurrences(of: "reordered", with: "sorted"))
        let updated = try await CatalogueVectors.prepare(texts: [catalogue] + GuideSearch.documents(for: changed).map(\.text),
            embedding: embedding, cached: second)
        #expect(await embedding.count == texts.count + 1)
        #expect(updated.vector(forText: catalogue) == first.vector(forText: catalogue))
        #expect(updated.vector(forText: documents[0].text) == nil)
    }
}

extension AppGuidesTests {
    @Test func formatterAcceptsPreparedValuesAndPreservesNilBytes() throws {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let scene = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: scene)
        defer { withExtendedLifetime((secrets, scene)) {} }
        let value: JSONValue = .object(["result": .string("unchanged")])
        for surface in [ToolSurface.tagged] {
            let unchanged = try formatter.finish("open_session", value, notice: nil, output: CallOutput(), surface: surface)
            #expect(unchanged == MCPRouter.toolResult(value))
            let head = GuideHead(header: try Self.fixture().header, text: "<data>&")
            let actual = try formatter.finish("open_session", value, notice: nil, output: CallOutput(), surface: surface,
                guideHead: head)
            let text = try #require(actual["content"].array?.first?["text"].string)
            let prefix = try #require(unchanged["content"].array?.first?["text"].string)
            #expect(text.hasPrefix(prefix + "\n\n"))
            #expect(text.contains("<guide>") == true)
        }
    }
}

extension AppGuidesTests {
    @Test
    func attachedGuideThroughFacade() async throws {
        let guides = try await make([Self.fixture()])
        let session = ToolResultSession()
        session.scene = SceneSnapshot(bundleID: app.bundleID, appName: "Sketchpad", windowTitle: "Drawing",
            viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [])
        let tools = AutomationTools(session: session, profile: Self.privateProfile, guides: guides, resolveGuideApp: { _ in self.app })
        #expect(guides.head(for: app) != nil)
        let answer = try await tools.call("open_session", .object(["app": .string(app.bundleID)]))
        let text = try #require(answer["content"].array?.first?["text"].string)
        #expect(text.contains("<guide>"))
        #expect(text.contains("The canvas holds the drawing."))
        #expect(session.calls == ["open"])
    }

    @Test func attachedPrivateGuideHasNoReadCapability() async throws {
        let guides = try await AppGuides.load(sources: [Source(values: [Self.fixture()])],
            estimateTokens: { ($0.count + 3) / 4 }, similarity: { _, _ in 0 })
        let session = ToolResultSession()
        let tools = AutomationTools(session: session, profile: Self.privateProfile, guides: guides, resolveGuideApp: { _ in self.app })
        #expect(tools.guidesEnabled)
        let answer = try await tools.call("find", .object(["query": .string("read application guide")]))
        let text = answer["content"].array?.first?["text"].string ?? ""
        #expect(!text.contains("read_guide"))
        #expect(!tools.toolDefinitions.contains { $0["name"].string == "read_guide" })
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("call", .object(["name": .string("read_guide"), "arguments": .object(["app": .string(app.bundleID)])]))
        }
        #expect(session.calls.isEmpty)
    }
}

extension AppGuidesTests {
    @Test func factoryLoadsOutsideMainActor() async throws {
        let guides = try await AppGuides.load(sources: [ConcurrentSource(values: [Self.fixture()])],
            estimateTokens: { ($0.count + 3) / 4 }, similarity: { _, _ in 0 })
        #expect(guides.head(for: app) != nil)
    }

    private nonisolated struct ConcurrentSource: AppGuideSource {
        let values: [AppGuide]
        func guides() throws -> [AppGuide] {
            #expect(!Thread.isMainThread)
            return values
        }
    }
}

extension AppGuidesTests {
    @Test func attachedSectionsReportTheOmittedBudgetWithoutAnIndexMode() async throws {
        let guides = try await AppGuides.load(sources: [Source(values: [Self.fixture()])],
            tokenCeiling: { _ in 20 }, estimateTokens: { ($0.count + 3) / 4 }, similarity: { _, _ in 0 })
        let selection = await guides.sections(for: app, todo: ["layers export canvas paint"], budgetTokens: 1, coveredBy: [])
        #expect(selection.sections.isEmpty)
        #expect(selection.leftOut > 0)
        #expect(guides.head(for: app) != nil)
    }

    @Test func languageOnlyLocaleAcceptsRegionalGuide() async throws {
        let guides = try await make([Self.fixture(locale: "it-IT")])
        #expect(guides.head(for: .init(bundleID: app.bundleID, version: nil, locale: "it")) != nil)
    }
}

extension AppGuidesTests {
    @Test func parallelReadDoesNotInheritAnotherCallsGuide() async throws {
        let guides = try await make([Self.fixture()])
        let gate = GuideReadGate()
        let session = ToolResultSession()
        let tools = AutomationTools(session: session, capabilities: [SuspendedGuideRead(gate: gate)], profile: Self.privateProfile,
            guides: guides, resolveGuideApp: { _ in self.app })
        let read = Task { try await tools.call("call", .object(["name": .string("guide_test.read"),
            "arguments": .object([:])])) }
        await gate.started()
        _ = try await tools.call("open_session", .object(["app": .string(app.bundleID)]))
        await gate.release()
        let answer = try await read.value
        #expect(answer["content"].array?.first?["text"].string?.contains("The canvas holds") != true)
    }
}

extension AppGuidesTests {
    private actor GuideReadGate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation in
                waiting = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        func started() async {
            if waiting != nil { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func release() { waiting?.resume(); waiting = nil }
    }

    private nonisolated struct SuspendedGuideRead: CapabilityProviding {
        let gate: GuideReadGate
        let family = "guide_test"
        var contracts: [CapabilityContract] {
            [.init(id: .init(rawValue: "guide_test.read"), group: "inspection", description: "Read state.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:]),
                    "additionalProperties": .bool(false)]), effect: .read, interruption: .readOnly,
                verification: .none(reason: "read only"), channel: .braus,
                origin: .registered(provider: "guide_test"), memory: .notRecorded(reason: "read only"),
                takesSession: false, parallelSafe: true)]
        }
        func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
            await gate.pause()
            return .string("Read complete.")
        }
    }
}

extension AppGuidesTests {
    @MainActor
    @Test func openCompositionIgnoresInjectedPrivateGuide() async throws {
        let guide = try await make([Self.fixture()])
        let session = ToolResultSession()
        let tools = AutomationTools(session: session, profile: SessionProfile(attendance: .none, level: .actConnectors, memory: .readLearn,
                catalogue: .open, takeover: false, options: .init(), name: "open"), guides: guide,
                                    resolveGuideApp: { _ in self.app })
        #expect(tools.guides == nil)
        #expect(!tools.guidesEnabled)
        #expect(!tools.toolDefinitions.contains { $0["name"].string == "read_guide" })
        let answer = try await tools.call("open_session", .object(["app": .string(app.bundleID)]))
        let text = answer["content"].array?.first?["text"].string ?? ""
        #expect(!text.contains("<guide>"))
        #expect(!text.contains("The canvas holds the drawing."))
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("call", .object(["name": .string("read_guide"),
                "arguments": .object(["app": .string(app.bundleID)])]))
        }
    }
}
