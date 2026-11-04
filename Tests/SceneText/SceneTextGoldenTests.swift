import Foundation
import PerceptionCore
import Testing

struct SceneTextGoldenTests {
    @Test(.disabled("needs attested scene fixtures"))
    @MainActor
    func requiredDelivery() async throws {
        let scenes = try GoldenScene.all()
        #expect(scenes.count == 10)
        #expect(scenes.filter { $0.role == "primary" }.count == 8)
        #expect(scenes.filter { $0.role == "supplement" }.count == 2)
        #expect(scenes.filter { !$0.scene.outOfViewFields.isEmpty }.count >= 2)
        #expect(scenes.contains { item in
            let labels = item.scene.outOfViewFields.map(\.label)
            return Set(labels).count < labels.count
        })
        #expect(scenes.contains { $0.scene.elements.contains { $0.label.contains("\n") } })
        #expect(scenes.contains { $0.scene.elements.contains { $0.label.hasPrefix("## ") } })
        var hasMemory = false
        for scene in scenes {
            let rendered = try await SceneTextUnderTest.render(scene.scene)
            hasMemory = hasMemory || !rendered.brainParts.isEmpty
        }
        #expect(hasMemory)
    }

    @Test(.disabled("needs attested scene fixtures"))
    func v1Matches() throws {
        for item in try GoldenScene.all() {
            #expect(Data(item.scene.text().utf8) == Data(item.textV1.utf8), "\(item.name): v1 bytes differ")
        }
    }

    @Test(.disabled("needs attested scene fixtures"))
    @MainActor
    func adapterUsesCurrentSafeCuts() async throws {
        for item in try GoldenScene.all() {
            let rendered = try await SceneTextUnderTest.render(item.scene)
            #expect(rendered.text == item.scene.text(cuts: .safe), "\(item.name): current adapter bytes differ")
            #expect(rendered.kind == nil)
        }
    }

    @Test(.disabled("needs attested scene fixtures"))
    func outOfViewSectionIsLast() throws {
        let scenes = try GoldenScene.all().filter { !$0.scene.outOfViewFields.isEmpty }
        #expect(scenes.count >= 2)
        let heading = "## past the window's edge (read only, not visible)\n"
        for item in scenes {
            var visible = item.scene
            visible.outOfViewFields = []
            let prefix = Array(visible.text().utf8)
            let bytes = Array(item.textV1.utf8)
            #expect(bytes.starts(with: prefix), "\(item.name): visible text differs")
            let tail = String(decoding: bytes.dropFirst(prefix.count), as: UTF8.self)
            #expect(tail.hasPrefix(heading))
            let lines = tail.split(separator: "\n")
            #expect(lines.count == item.scene.outOfViewFields.count + 1)
            #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("[field] ") })
        }
    }
}

extension SceneTextGoldenTests {
    @Test(.disabled("needs attested scene fixtures"))
    @MainActor
    func currentModelTextOmitsEmptySelections() async throws {
        for item in try GoldenScene.all() {
            let current = try await SceneTextUnderTest.render(item.scene)
            for element in item.scene.elements {
                if let range = element.selectedRange, range.length == 0, let value = element.value {
                    #expect(!current.text.contains("[sel \(range.location)..\(range.location)/\(value.utf16.count)]"))
                }
            }
        }
    }
}


extension SceneTextGoldenTests {
    /// The manual future golden remains independent from the current safe-cut renderer.
    /// Add scoped known issues only after inspecting each delivered, reviewed case.
    @Test(.disabled("needs attested fixtures and case-specific future-format ratchets"))
    @MainActor
    func futureFormatMatchesManualDesign() async throws {
        for item in try GoldenScene.all() {
            let current = try await SceneTextUnderTest.render(item.scene)
            #expect(Data(current.text.utf8) == Data(item.textV2.utf8),
                    "\(item.name): future design bytes differ")
        }
    }
}
