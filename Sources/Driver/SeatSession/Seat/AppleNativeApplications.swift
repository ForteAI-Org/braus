//
//  AppleNativeApplications.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/10/2026.
//

import Foundation
import Security
import Synchronization

/// AppleNativeApplications says whether a bundle is an Apple application drawn with AppKit, the
/// ones whose ordinary windows are acted on through accessibility before a click is posted.
///
/// The evidence is the code signature and not the bundle identifier, which anything can claim:
/// the bundle satisfies `anchor apple`, and it is not Mac Catalyst, whose UIKit controls were not
/// measured to take accessibility actions as AppKit's do. A signature that cannot be read is not
/// Apple's, and a binary that cannot be read is taken for Catalyst: both leave the click posted.
/// Both readings are injected, and an answer is kept per bundle path.
nonisolated final class AppleNativeApplications: Sendable {

    /// The readings the shipping seat takes.
    static let shipping = AppleNativeApplications(isAppleSigned: signedByApple, isMacCatalyst: buildsForMacCatalyst)

    private let isAppleSigned: @Sendable (URL) -> Bool
    private let isMacCatalyst: @Sendable (URL) -> Bool
    private let answers = Mutex<[String: Bool]>([:])

    init(
        isAppleSigned: @escaping @Sendable (URL) -> Bool,
        isMacCatalyst: @escaping @Sendable (URL) -> Bool
    ) {
        self.isAppleSigned = isAppleSigned
        self.isMacCatalyst = isMacCatalyst
    }

    func contains(bundleAt url: URL) -> Bool {
        let path = url.path
        if let known = answers.withLock({ $0[path] }) { return known }
        let answer = isAppleSigned(url) && !isMacCatalyst(url)
        answers.withLock { $0[path] = answer }
        return answer
    }

    /// Whether the bundle satisfies `anchor apple`. The main executable's signature is enough to
    /// name the signer, so the bundle's resources are not hashed, which takes about 100 ms on Safari.
    static func signedByApple(_ bundleURL: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement)
            == errSecSuccess
    }

    /// Whether the bundle is Mac Catalyst: its Info.plist names a UIKit device family, or a slice
    /// of its main executable is built for the Catalyst platform. Unreadable is taken as Catalyst.
    static func buildsForMacCatalyst(_ bundleURL: URL) -> Bool {
        guard let bundle = Bundle(url: bundleURL), let executable = bundle.executableURL else { return true }
        if bundle.object(forInfoDictionaryKey: "UIDeviceFamily") != nil { return true }
        return machOBuildsForMacCatalyst(executable)
    }

    /// The Mach-O header's `LC_BUILD_VERSION` platform of every slice of a thin or fat file.
    static func machOBuildsForMacCatalyst(_ executable: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: executable) else { return true }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 4096), head.count >= 8 else { return true }
        var offsets = [UInt64(0)]
        if head.bigEndian(at: 0) == 0xcafebabe {
            let count = Int(head.bigEndian(at: 4))
            guard count <= 16, head.count >= 8 + 20 * count else { return true }
            offsets = (0..<count).map { UInt64(head.bigEndian(at: 8 + 20 * $0 + 8)) }
        }
        return offsets.contains { offset in
            guard (try? file.seek(toOffset: offset)) != nil, let header = try? file.read(upToCount: 32),
                  header.count == 32, header.littleEndian(at: 0) == 0xfeedfacf
            else { return true }
            let size = Int(header.littleEndian(at: 20))
            guard size <= 1 << 20, (try? file.seek(toOffset: offset + 32)) != nil,
                  let commands = try? file.read(upToCount: size), commands.count == size
            else { return true }
            var position = 0
            while position + 8 <= commands.count {
                let command = commands.littleEndian(at: position)
                let length  = Int(commands.littleEndian(at: position + 4))
                guard length >= 8 else { return true }
                // LC_BUILD_VERSION, whose platform follows the two words of the load command.
                if command == 0x32, position + 12 <= commands.count {
                    return commands.littleEndian(at: position + 8) == 6
                }
                position += length
            }
            return false
        }
    }
}

nonisolated private extension Data {

    func littleEndian(at offset: Int) -> UInt32 {
        UInt32(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }

    func bigEndian(at offset: Int) -> UInt32 {
        UInt32(bigEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }
}
