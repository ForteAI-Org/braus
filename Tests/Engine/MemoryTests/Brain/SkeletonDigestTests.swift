import EngineCore
import Foundation
import Memory
import Testing

@Suite("Skeleton digest")
struct SkeletonDigestTests {
    @Test
    func matchesDigest16OfCanonical() throws {
        let skeleton = SceneSkeleton(
            surface: .window,
            rolesByPath: ["toolbar": ["AXButton", "AXCheckBox"], "": ["AXWindow"]],
            captionsByPath: ["toolbar": [.init(role: "AXButton", label: "Save")]],
            collections: ["files", "sidebar"]
        )
        let digest = SkeletonDigest(skeleton)
        #expect(digest.bytes == Digest16.of(skeleton.canonical))
        #expect(try #require(SkeletonDigest(bytes: digest.bytes)) == digest)
        var reordered = skeleton
        reordered.rolesByPath = ["": ["AXWindow"], "toolbar": ["AXCheckBox", "AXButton"]]
        reordered.collections = ["sidebar", "files"]
        #expect(SkeletonDigest(reordered) == digest)
        reordered.surface = .sheet
        #expect(SkeletonDigest(reordered) != digest)
    }

    @Test
    func bigEndianHalvesAndSlicedData() throws {
        let bytes = Data([255] + Array(UInt8(0)...UInt8(15)))
        let digest = try #require(SkeletonDigest(bytes: bytes.dropFirst()))
        #expect(digest.high == 0x0001_0203_0405_0607)
        #expect(digest.low == 0x0809_0a0b_0c0d_0e0f)
        #expect(digest.bytes == Data(0...15))
        #expect(Set([digest, try #require(SkeletonDigest(bytes: digest.bytes))]).count == 1)
    }

    @Test(arguments: [0, 15, 17, 32])
    func rejectsOtherLengths(_ count: Int) {
        #expect(SkeletonDigest(bytes: Data(repeating: 0, count: count)) == nil)
    }
}
