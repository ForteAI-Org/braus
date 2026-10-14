//
//  HalfPrecisionTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import Foundation
@testable import LocalEmbedding
import Testing

/// HalfPrecisionTests check the conversion of 4462bbe, which decodes binary16 weights without `Float16` so the Intel slice
/// builds: every bit pattern against the hardware's own conversion where `Float16` exists, the named edge cases on every
/// architecture, and the safetensors reader converting F16 and BF16 tensors from a file. The criterion, fixed before the
/// run: every value that is not a NaN equals the hardware's bit for bit, signed zeros and subnormals included; a NaN stays
/// a NaN with its sign and its payload in place (the hardware also sets the quiet bit of a signaling one, which no weight
/// of a model holds). The pinned models store float32 (E5) and bfloat16 (Granite): this path is for a model in binary16.
@Suite("Half-precision weights decoded bit by bit")
struct HalfPrecisionTests {

    #if arch(arm64)
    @Test("every one of the 65,536 binary16 patterns converts as the hardware's Float16 does")
    func everyPattern() {
        var mismatches: [UInt16] = []
        for value in 0...UInt16.max {
            let hardware = Float(Float16(bitPattern: value))
            let decoded = SafetensorsFile.float(fromHalfBits: value)
            if hardware.isNaN {
                let quiet: UInt32 = 0x0040_0000
                guard decoded.isNaN, decoded.sign == hardware.sign,
                      decoded.bitPattern | quiet == hardware.bitPattern | quiet else { mismatches.append(value); continue }
            } else if decoded.bitPattern != hardware.bitPattern {
                mismatches.append(value)
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(8).map { String($0, radix: 16) })")
    }
    #endif

    @Test("signed zeros, subnormals, the extremes, the infinities and the NaNs, on every architecture")
    func edges() {
        let cases: [(UInt16, Float)] = [
            (0x0000, 0), (0x8000, -0.0), (0x0001, 0x1p-24), (0x8001, -0x1p-24), (0x03FF, 0x3FFp-24), (0x0400, 0x1p-14),
            (0x3C00, 1), (0xBC00, -1), (0x3555, 0x1.554p-2), (0x7BFF, 65504), (0xFBFF, -65504),
            (0x7C00, .infinity), (0xFC00, -.infinity),
        ]
        for (bits, expected) in cases {
            let decoded = SafetensorsFile.float(fromHalfBits: bits)
            #expect(decoded.bitPattern == expected.bitPattern, "\(String(bits, radix: 16)): \(decoded) for \(expected)")
        }
        let quiet = SafetensorsFile.float(fromHalfBits: 0x7E00), signaling = SafetensorsFile.float(fromHalfBits: 0xFC01)
        #expect(quiet.isNaN && quiet.sign == .plus && quiet.bitPattern == 0x7FC0_0000)
        #expect(signaling.isNaN && signaling.sign == .minus && signaling.bitPattern & 0x003F_FFFF == 1 << 13, "the payload keeps its place")
    }

    @Test("a safetensors file of F16 and BF16 tensors reads back as the float32 values it holds")
    func file() throws {
        let half: [UInt16] = [0x0000, 0x8000, 0x0001, 0x3C00, 0xC000, 0x7BFF, 0xFC00, 0x3555]
        let brain: [UInt16] = [0x0000, 0x8000, 0x3F80, 0xC040, 0x7F80, 0x0001, 0x4049, 0xFF7F]
        let header = #"{"h":{"dtype":"F16","shape":[2,4],"data_offsets":[0,16]},"b":{"dtype":"BF16","shape":[2,4],"data_offsets":[16,32]}}"#
        var data = Data()
        withUnsafeBytes(of: UInt64(header.utf8.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: header.utf8)
        for value in half + brain { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("half-\(UUID().uuidString).safetensors")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try SafetensorsFile(path: url.path)
        let h = try file.floats(try file.tensor("h", shape: [2, 4]))
        #expect(h.map(\.bitPattern) == half.map { SafetensorsFile.float(fromHalfBits: $0).bitPattern })
        #expect(h[1].sign == .minus && h[1] == 0 && h[5] == 65504 && h[6] == -.infinity)
        let b = try file.floats(try file.tensor("b", shape: [2, 4]))
        #expect(b.map(\.bitPattern) == brain.map { UInt32($0) << 16 })
        #expect(b[2] == 1 && b[3] == -3 && b[4] == .infinity && b[5] == Float(bitPattern: 0x0001_0000))
    }
}
