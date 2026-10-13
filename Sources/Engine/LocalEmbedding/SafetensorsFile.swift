//
//  SafetensorsFile.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Darwin
import Foundation

/// SafetensorsFile is a read-only memory map of one `.safetensors` file: an 8-byte little-endian header
/// length, a JSON header naming each tensor's dtype, shape and byte range, then the raw data. The mapping is
/// owned by this object and released when it is deinitialized; the pointers it hands out (`floats`) are
/// valid only while the object lives, and nothing writes through them. Only the pages a caller touches are
/// read from disk: a word embedding table of a quarter of a million rows costs the rows that are looked up.
final class SafetensorsFile: @unchecked Sendable {
    // Sendable because the mapping is read-only and immutable from init to deinit; no state changes after init.

    /// Tensor is one entry of the header.
    struct Tensor {
        let dtype: String
        let shape: [Int]
        let start: Int
        let end: Int

        var count: Int { shape.reduce(1, *) }
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadable(path: String, errno: Int32)
        case malformedHeader(path: String)
        case missingTensor(String)
        case unsupported(name: String, dtype: String)
        case shape(name: String, expected: [Int], found: [Int])

        var description: String {
            switch self {
                case .unreadable(let path, let code): "cannot map \(path): \(String(cString: strerror(code)))"
                case .malformedHeader(let path): "\(path) has no valid safetensors header"
                case .missingTensor(let name): "the weights have no tensor \(name)"
                case .unsupported(let name, let dtype): "tensor \(name) has the unsupported type \(dtype)"
                case .shape(let name, let expected, let found): "tensor \(name) has shape \(found), expected \(expected)"
            }
        }
    }

    let path: String
    let tensors: [String: Tensor]
    private let base: UnsafeRawPointer
    private let length: Int
    private let dataStart: Int

    init(path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw Failure.unreadable(path: path, errno: errno) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Failure.unreadable(path: path, errno: errno) }
        let length = Int(status.st_size)
        guard length > 8, let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0), mapped != MAP_FAILED else {
            throw Failure.unreadable(path: path, errno: errno)
        }
        let base = UnsafeRawPointer(mapped)
        let headerLength = Int(base.loadUnaligned(as: UInt64.self).littleEndian)
        guard headerLength > 0, 8 + headerLength <= length,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes: base + 8, count: headerLength)) as? [String: Any] else {
            munmap(mapped, length)
            throw Failure.malformedHeader(path: path)
        }
        var tensors: [String: Tensor] = [:]
        for (name, value) in object where name != "__metadata__" {
            guard let entry = value as? [String: Any], let dtype = entry["dtype"] as? String, let shape = entry["shape"] as? [Int],
                  let offsets = entry["data_offsets"] as? [Int], offsets.count == 2, offsets[0] <= offsets[1],
                  8 + headerLength + offsets[1] <= length else {
                munmap(mapped, length)
                throw Failure.malformedHeader(path: path)
            }
            tensors[name] = Tensor(dtype: dtype, shape: shape, start: offsets[0], end: offsets[1])
        }
        self.path      = path
        self.tensors   = tensors
        self.base      = base
        self.length    = length
        self.dataStart = 8 + headerLength
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), length)
    }

    /// The tensor named, checked against the shape the model's configuration expects.
    func tensor(_ name: String, shape: [Int]) throws -> Tensor {
        guard let tensor = tensors[name] else { throw Failure.missingTensor(name) }
        guard tensor.shape == shape else { throw Failure.shape(name: name, expected: shape, found: tensor.shape) }
        let width = try Self.width(of: tensor.dtype, name: name)
        guard tensor.end - tensor.start == tensor.count * width else { throw Failure.malformedHeader(path: path) }
        return tensor
    }

    /// A float32 tensor's data in place, when it is stored as aligned float32: zero copy, valid while the file lives.
    func mappedFloats(_ tensor: Tensor) -> UnsafePointer<Float>? {
        let address = base + dataStart + tensor.start
        guard tensor.dtype == "F32", Int(bitPattern: address) % MemoryLayout<Float>.alignment == 0 else { return nil }
        return address.assumingMemoryBound(to: Float.self)
    }

    /// A tensor's data converted to float32, whatever its stored type (F32, F16, BF16).
    func floats(_ tensor: Tensor) throws -> [Float] {
        try floats(tensor, rows: 0..<(tensor.shape.first ?? 1))
    }

    /// The rows of a matrix tensor converted to float32: what a lookup of a few rows of a large table reads.
    func floats(_ tensor: Tensor, rows: Range<Int>) throws -> [Float] {
        let columns = tensor.shape.count > 1 ? tensor.shape.dropFirst().reduce(1, *) : 1
        var output = [Float](repeating: 0, count: rows.count * columns)
        try copyRow(tensor, rows: rows, columns: columns, into: &output)
        return output
    }

    /// Writes row `row` of a matrix tensor, converted to float32, into `destination`.
    func copyRow(_ tensor: Tensor, row: Int, into destination: UnsafeMutablePointer<Float>) throws {
        let columns = tensor.shape.dropFirst().reduce(1, *)
        let width = try Self.width(of: tensor.dtype, name: "row")
        let source = base + dataStart + tensor.start + row * columns * width
        Self.convert(source, dtype: tensor.dtype, count: columns, into: destination)
    }

    private func copyRow(_ tensor: Tensor, rows: Range<Int>, columns: Int, into output: inout [Float]) throws {
        let width = try Self.width(of: tensor.dtype, name: "rows")
        let source = base + dataStart + tensor.start + rows.lowerBound * columns * width
        output.withUnsafeMutableBufferPointer { buffer in
            Self.convert(source, dtype: tensor.dtype, count: rows.count * columns, into: buffer.baseAddress!)
        }
    }

    private static func width(of dtype: String, name: String) throws -> Int {
        switch dtype {
            case "F32"       : 4
            case "F16", "BF16": 2
            default          : throw Failure.unsupported(name: name, dtype: dtype)
        }
    }

    private static func convert(_ source: UnsafeRawPointer, dtype: String, count: Int, into destination: UnsafeMutablePointer<Float>) {
        switch dtype {
            case "F32":
                memcpy(destination, source, count * 4)
            case "BF16":
                for index in 0..<count {
                    let bits = UInt32(source.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self).littleEndian) << 16
                    destination[index] = Float(bitPattern: bits)
                }
            default:
                for index in 0..<count {
                    destination[index] = float(fromHalfBits: source.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self).littleEndian)
                }
        }
    }

    /// IEEE 754 binary16 to float32, bit by bit. `Float16` itself is unavailable on
    /// x86_64 macOS and the app ships universal, so the conversion cannot rely on it.
    static func float(fromHalfBits bits: UInt16) -> Float {
        let sign     = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits >> 10) & 0x1F
        let fraction = UInt32(bits & 0x03FF)
        switch exponent {
            case 0:
                // Zero or subnormal: fraction × 2^-24, with the sign reapplied.
                let magnitude = Float(fraction) * Float(bitPattern: 0x3380_0000)
                return sign == 0 ? magnitude : -magnitude
            case 0x1F:
                // Infinity or NaN; the payload keeps its position.
                return Float(bitPattern: sign | 0x7F80_0000 | (fraction << 13))
            default:
                return Float(bitPattern: sign | ((exponent + 112) << 23) | (fraction << 13))
        }
    }
}
