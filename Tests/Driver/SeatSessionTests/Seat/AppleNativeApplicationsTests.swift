//
//  AppleNativeApplicationsTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/10/2026.
//

import Foundation
@testable import SeatSession
import Testing

/// Which bundles an ordinary window's clicks go through accessibility for: the signature and the
/// Catalyst readings are injected, and the Mach-O reading and the shipping readings are proved on
/// bytes and on the system's own applications.
@Suite("Apple native applications")
struct AppleNativeApplicationsTests {

    private static let bundle = URL(fileURLWithPath: "/Applications/Example.app")

    private static func check(apple: Bool, catalyst: Bool) -> AppleNativeApplications {
        AppleNativeApplications(isAppleSigned: { _ in apple }, isMacCatalyst: { _ in catalyst })
    }

    @Test("only an Apple signed bundle that is not Mac Catalyst is native", arguments: [
        (true , false, true ),
        (true , true , false),
        (false, false, false),
        (false, true , false),
    ])
    func theDecision(apple: Bool, catalyst: Bool, native: Bool) {
        #expect(Self.check(apple: apple, catalyst: catalyst).contains(bundleAt: Self.bundle) == native)
    }

    @Test("a bundle is read once, whatever the answer")
    func theAnswerIsKept() {
        final class Count: @unchecked Sendable { var signatures = 0 }
        let count = Count()
        let check = AppleNativeApplications(
            isAppleSigned: { _ in count.signatures += 1; return false },
            isMacCatalyst: { _ in false }
        )
        #expect(!check.contains(bundleAt: Self.bundle))
        #expect(!check.contains(bundleAt: Self.bundle))
        #expect(count.signatures == 1)
    }

    // MARK: Extension content

    private static let host      = URL(fileURLWithPath: "/System/Applications/Host.app")
    private static let appleExt  = URL(fileURLWithPath: "/System/Library/ExtensionKit/Apple.appex")
    private static let otherExt  = URL(fileURLWithPath: "/Applications/Other.app/Contents/Extension.appex")

    private static func extensions(appleHost: Bool = true) -> AppleNativeApplications {
        AppleNativeApplications(
            isAppleSigned: { $0 == appleExt || ($0 == host && appleHost) },
            isMacCatalyst: { _ in false }
        )
    }

    @Test("an Apple extension in an Apple application qualifies, any other pairing does not")
    func theExtensionDecision() {
        #expect( Self.extensions().contains(extensionBundleAt: Self.appleExt, hostedBy: Self.host))
        #expect(!Self.extensions().contains(extensionBundleAt: Self.otherExt, hostedBy: Self.host))
        #expect(!Self.extensions(appleHost: false).contains(extensionBundleAt: Self.appleExt, hostedBy: Self.host))
    }

    @Test("an extension whose signature cannot be read is not Apple's, and is read once")
    func anUnreadableExtensionIsRefused() {
        final class Count: @unchecked Sendable { var reads = 0 }
        let count = Count()
        let check = AppleNativeApplications(
            isAppleSigned: { $0 == Self.host ? true : { count.reads += 1; return false }() },
            isMacCatalyst: { _ in false }
        )
        #expect(!check.contains(extensionBundleAt: Self.otherExt, hostedBy: Self.host))
        #expect(!check.contains(extensionBundleAt: Self.otherExt, hostedBy: Self.host))
        #expect(count.reads == 1)
    }

    // MARK: Mach-O

    /// One thin 64 bit slice: a load command that names no platform, and the build version's if any.
    private static func slice(platform: UInt32?) -> Data {
        var commands = Data()
        for word in [UInt32(0x1b), 24, 0, 0, 0, 0] { commands.append(word.littleEndianBytes) }
        if let platform {
            for word in [UInt32(0x32), 24, platform, 0, 0, 0] { commands.append(word.littleEndianBytes) }
        }
        var data = Data()
        for word in [UInt32(0xfeedfacf), 0x0100000c, 0, 2, platform == nil ? 1 : 2, UInt32(commands.count), 0, 0] {
            data.append(word.littleEndianBytes)
        }
        return data + commands
    }

    private static func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "macho-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test("a slice built for Mac Catalyst is read from its build version")
    func aCatalystSliceIsRead() throws {
        let catalyst = try Self.file(Self.slice(platform: 6))
        let macOS    = try Self.file(Self.slice(platform: 1))
        let none     = try Self.file(Self.slice(platform: nil))
        defer { [catalyst, macOS, none].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(AppleNativeApplications.machOBuildsForMacCatalyst(catalyst))
        #expect(!AppleNativeApplications.machOBuildsForMacCatalyst(macOS))
        #expect(!AppleNativeApplications.machOBuildsForMacCatalyst(none))
    }

    @Test("a fat file is Catalyst when any slice is, and a file that is no Mach-O is taken for Catalyst")
    func aFatFileAndAnUnreadableOne() throws {
        let first  = Self.slice(platform: 1)
        let second = Self.slice(platform: 6)
        var fat = Data()
        for word in [UInt32(0xcafebabe), 2] { fat.append(word.bigEndianBytes) }
        let firstOffset  = UInt32(4096)
        let secondOffset = UInt32(8192)
        for (offset, size) in [(firstOffset, first.count), (secondOffset, second.count)] {
            for word in [UInt32(0x0100000c), 0, offset, UInt32(size), 12] { fat.append(word.bigEndianBytes) }
        }
        fat.append(Data(count: Int(firstOffset) - fat.count))
        fat.append(first)
        fat.append(Data(count: Int(secondOffset) - fat.count))
        fat.append(second)
        let url     = try Self.file(fat)
        let garbage = try Self.file(Data(repeating: 7, count: 64))
        defer { [url, garbage].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(AppleNativeApplications.machOBuildsForMacCatalyst(url))
        #expect(AppleNativeApplications.machOBuildsForMacCatalyst(garbage))
        #expect(AppleNativeApplications.machOBuildsForMacCatalyst(URL(fileURLWithPath: "/no/such/binary")))
    }

    // MARK: The system's own readings

    @Test("Finder is Apple's and AppKit's, a Catalyst application is not native, and this test bundle is not Apple's")
    func theShippingReadings() throws {
        let check  = AppleNativeApplications.shipping
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        #expect(check.contains(bundleAt: finder))
        // Any Catalyst application of the system's: Messages and Maps both are, and the first present is used.
        let catalyst = ["Maps", "Messages", "Clock", "Books"]
            .map { URL(fileURLWithPath: "/System/Applications/\($0).app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if let catalyst {
            #expect(AppleNativeApplications.signedByApple(catalyst))
            #expect(!check.contains(bundleAt: catalyst))
            // The binary alone says it too, without the Info.plist's device family.
            let executable = try #require(Bundle(url: catalyst)?.executableURL)
            #expect(AppleNativeApplications.machOBuildsForMacCatalyst(executable))
        }
        #expect(!check.contains(bundleAt: Bundle(for: Anchor.self).bundleURL))
    }

    private final class Anchor {}
}

private extension UInt32 {
    var littleEndianBytes: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
    var bigEndianBytes   : Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
