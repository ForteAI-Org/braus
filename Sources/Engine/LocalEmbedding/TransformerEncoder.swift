//
//  TransformerEncoder.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Accelerate
import Foundation
internal import LocalEmbeddingKernels

/// TransformerEncoder is the forward pass of a BERT-family encoder as `transformers` runs `BertModel` and
/// `XLMRobertaModel` in inference: word, position and type embeddings with a layer norm, then post-norm
/// layers of multi-head self-attention and a GELU feed-forward, each with its residual and layer norm. Only
/// one unpadded sequence is encoded at a time, so no attention mask is needed. Matrix products run on
/// Accelerate's BLAS (`LocalEmbeddingKernels`). The weights are read once at init and never changed: float32 weights stay in the file's
/// mapping, others are converted to float32; word embeddings are read row by row from the mapping, so the
/// table's quarter of a million rows costs only the rows a text uses.
final class TransformerEncoder: @unchecked Sendable {
    // Sendable: every stored property is immutable after init, and `encode` allocates its own buffers.

    /// Configuration is what `config.json` says of the architecture, with the position offset of the family:
    /// 0 for BERT, the padding index plus one for RoBERTa, whose positions start after it.
    struct Configuration: Equatable {
        let layers: Int
        let hidden: Int
        let heads: Int
        let intermediate: Int
        let vocabulary: Int
        let positions: Int
        let types: Int
        let layerNormEpsilon: Float
        let positionOffset: Int

        init(contentsOf url: URL) throws {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UnigramTokenizer.Failure.unreadable(url.lastPathComponent)
            }
            func integer(_ key: String) throws -> Int {
                guard let value = object[key] as? Int else { throw UnigramTokenizer.Failure.unsupported("a config without \(key)") }
                return value
            }
            guard object["hidden_act"] as? String == "gelu" else { throw UnigramTokenizer.Failure.unsupported("an activation other than gelu") }
            guard (object["position_embedding_type"] as? String ?? "absolute") == "absolute" else {
                throw UnigramTokenizer.Failure.unsupported("relative position embeddings")
            }
            layers       = try integer("num_hidden_layers")
            hidden       = try integer("hidden_size")
            heads        = try integer("num_attention_heads")
            intermediate = try integer("intermediate_size")
            vocabulary   = try integer("vocab_size")
            positions    = try integer("max_position_embeddings")
            types        = try integer("type_vocab_size")
            layerNormEpsilon = Float((object["layer_norm_eps"] as? NSNumber)?.doubleValue ?? 1e-12)
            switch object["model_type"] as? String {
                case "bert"       : positionOffset = 0
                case "xlm-roberta": positionOffset = (object["pad_token_id"] as? Int ?? 1) + 1
                default           : throw UnigramTokenizer.Failure.unsupported("a model type other than bert and xlm-roberta")
            }
            guard hidden % heads == 0 else { throw UnigramTokenizer.Failure.unsupported("a hidden size not divisible by the heads") }
        }
    }

    /// Weights is one tensor as the forward pass reads it: in the file's mapping, or converted and owned.
    private enum Weights {
        case mapped(UnsafePointer<Float>)
        case owned([Float])

        func withPointer<R>(_ body: (UnsafePointer<Float>) -> R) -> R {
            switch self {
                case .mapped(let pointer): body(pointer)
                case .owned(let array): array.withUnsafeBufferPointer { body($0.baseAddress!) }
            }
        }
    }

    private struct Layer {
        let query, queryBias, key, keyBias, value, valueBias: Weights
        let attentionOut, attentionOutBias, attentionNorm, attentionNormBias: Weights
        let up, upBias, down, downBias, outputNorm, outputNormBias: Weights
    }

    let configuration: Configuration
    private let file: SafetensorsFile
    private let words: SafetensorsFile.Tensor
    private let positions: Weights
    private let type: Weights
    private let embeddingNorm: Weights
    private let embeddingNormBias: Weights
    private let layers: [Layer]

    init(weights url: URL, configuration: Configuration) throws {
        let file = try SafetensorsFile(path: url.path)
        let h = configuration.hidden, i = configuration.intermediate
        func load(_ name: String, _ shape: [Int]) throws -> Weights {
            let tensor = try file.tensor(name, shape: shape)
            if let mapped = file.mappedFloats(tensor) { return .mapped(mapped) }
            return .owned(try file.floats(tensor))
        }
        self.configuration     = configuration
        self.file              = file
        self.words             = try file.tensor("embeddings.word_embeddings.weight", shape: [configuration.vocabulary, h])
        self.positions         = try load("embeddings.position_embeddings.weight", [configuration.positions, h])
        self.type              = try load("embeddings.token_type_embeddings.weight", [configuration.types, h])
        self.embeddingNorm     = try load("embeddings.LayerNorm.weight", [h])
        self.embeddingNormBias = try load("embeddings.LayerNorm.bias", [h])
        self.layers = try (0..<configuration.layers).map { index in
            let p = "encoder.layer.\(index)."
            return Layer(
                query            : try load(p + "attention.self.query.weight", [h, h]),
                queryBias        : try load(p + "attention.self.query.bias", [h]),
                key              : try load(p + "attention.self.key.weight", [h, h]),
                keyBias          : try load(p + "attention.self.key.bias", [h]),
                value            : try load(p + "attention.self.value.weight", [h, h]),
                valueBias        : try load(p + "attention.self.value.bias", [h]),
                attentionOut     : try load(p + "attention.output.dense.weight", [h, h]),
                attentionOutBias : try load(p + "attention.output.dense.bias", [h]),
                attentionNorm    : try load(p + "attention.output.LayerNorm.weight", [h]),
                attentionNormBias: try load(p + "attention.output.LayerNorm.bias", [h]),
                up               : try load(p + "intermediate.dense.weight", [i, h]),
                upBias           : try load(p + "intermediate.dense.bias", [i]),
                down             : try load(p + "output.dense.weight", [h, i]),
                downBias         : try load(p + "output.dense.bias", [h]),
                outputNorm       : try load(p + "output.LayerNorm.weight", [h]),
                outputNormBias   : try load(p + "output.LayerNorm.bias", [h])
            )
        }
    }

    /// The last hidden states of one sequence of ids, `ids.count` rows of `hidden` floats, row major.
    func encode(_ ids: [Int]) throws -> [Float] {
        let n = ids.count, h = configuration.hidden
        guard n > 0, n + configuration.positionOffset <= configuration.positions else {
            throw UnigramTokenizer.Failure.unsupported("a sequence of \(n) tokens")
        }
        var x = [Float](repeating: 0, count: n * h)
        try x.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            for (row, id) in ids.enumerated() {
                guard id >= 0, id < configuration.vocabulary else { throw UnigramTokenizer.Failure.unsupported("token \(id)") }
                try file.copyRow(words, row: id, into: base + row * h)
            }
            positions.withPointer { pointer in
                for row in 0..<n { vDSP_vadd(base + row * h, 1, pointer + (row + configuration.positionOffset) * h, 1, base + row * h, 1, vDSP_Length(h)) }
            }
            type.withPointer { pointer in
                for row in 0..<n { vDSP_vadd(base + row * h, 1, pointer, 1, base + row * h, 1, vDSP_Length(h)) }
            }
        }
        layerNorm(&x, rows: n, weight: embeddingNorm, bias: embeddingNormBias)
        for layer in layers { forward(&x, rows: n, layer: layer) }
        return x
    }

    // MARK: The layers

    private func forward(_ x: inout [Float], rows n: Int, layer: Layer) {
        let h = configuration.hidden, heads = configuration.heads, d = h / heads
        let q = linear(x, rows: n, inputs: h, outputs: h, weight: layer.query, bias: layer.queryBias)
        let k = linear(x, rows: n, inputs: h, outputs: h, weight: layer.key, bias: layer.keyBias)
        let v = linear(x, rows: n, inputs: h, outputs: h, weight: layer.value, bias: layer.valueBias)
        var context = [Float](repeating: 0, count: n * h)
        var scores = [Float](repeating: 0, count: n * n)
        let scale = 1 / Float(d).squareRoot()
        q.withUnsafeBufferPointer { q in
            k.withUnsafeBufferPointer { k in
                v.withUnsafeBufferPointer { v in
                    context.withUnsafeMutableBufferPointer { context in
                        scores.withUnsafeMutableBufferPointer { scores in
                            for head in 0..<heads {
                                let offset = head * d
                                braus_sgemm(false, true, Int32(n), Int32(n), Int32(d), scale, q.baseAddress! + offset, Int32(h),
                                            k.baseAddress! + offset, Int32(h), 0, scores.baseAddress!, Int32(n))
                                for row in 0..<n { Self.softmax(scores.baseAddress! + row * n, count: n) }
                                braus_sgemm(false, false, Int32(n), Int32(d), Int32(n), 1, scores.baseAddress!, Int32(n),
                                            v.baseAddress! + offset, Int32(h), 0, context.baseAddress! + offset, Int32(h))
                            }
                        }
                    }
                }
            }
        }
        var attention = linear(context, rows: n, inputs: h, outputs: h, weight: layer.attentionOut, bias: layer.attentionOutBias)
        vDSP_vadd(attention, 1, x, 1, &attention, 1, vDSP_Length(n * h))
        layerNorm(&attention, rows: n, weight: layer.attentionNorm, bias: layer.attentionNormBias)
        var up = linear(attention, rows: n, inputs: h, outputs: configuration.intermediate, weight: layer.up, bias: layer.upBias)
        Self.gelu(&up)
        var down = linear(up, rows: n, inputs: configuration.intermediate, outputs: h, weight: layer.down, bias: layer.downBias)
        vDSP_vadd(down, 1, attention, 1, &down, 1, vDSP_Length(n * h))
        layerNorm(&down, rows: n, weight: layer.outputNorm, bias: layer.outputNormBias)
        x = down
    }

    /// `input · weightᵀ + bias`, with the weight stored as `transformers` keeps a linear layer: outputs × inputs.
    private func linear(_ input: [Float], rows n: Int, inputs: Int, outputs: Int, weight: Weights, bias: Weights) -> [Float] {
        var output = [Float](repeating: 0, count: n * outputs)
        bias.withPointer { bias in
            output.withUnsafeMutableBufferPointer { buffer in
                for row in 0..<n { memcpy(buffer.baseAddress! + row * outputs, bias, outputs * MemoryLayout<Float>.size) }
            }
        }
        weight.withPointer { weight in
            input.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { output in
                    braus_sgemm(false, true, Int32(n), Int32(outputs), Int32(inputs), 1, input.baseAddress!, Int32(inputs), weight,
                                Int32(inputs), 1, output.baseAddress!, Int32(outputs))
                }
            }
        }
        return output
    }

    private func layerNorm(_ x: inout [Float], rows n: Int, weight: Weights, bias: Weights) {
        let h = configuration.hidden
        let epsilon = configuration.layerNormEpsilon
        weight.withPointer { weight in
            bias.withPointer { bias in
                x.withUnsafeMutableBufferPointer { buffer in
                    for row in 0..<n {
                        let values = buffer.baseAddress! + row * h
                        var mean: Float = 0
                        vDSP_meanv(values, 1, &mean, vDSP_Length(h))
                        var variance: Float = 0
                        for index in 0..<h {
                            let centered = values[index] - mean
                            variance += centered * centered
                        }
                        variance /= Float(h)
                        let inverse = 1 / (variance + epsilon).squareRoot()
                        for index in 0..<h { values[index] = (values[index] - mean) * inverse * weight[index] + bias[index] }
                    }
                }
            }
        }
    }

    private static func softmax(_ values: UnsafeMutablePointer<Float>, count: Int) {
        var maximum: Float = 0
        vDSP_maxv(values, 1, &maximum, vDSP_Length(count))
        var sum: Float = 0
        for index in 0..<count {
            let value = Foundation.exp(values[index] - maximum)
            values[index] = value
            sum += value
        }
        let inverse = 1 / sum
        for index in 0..<count { values[index] *= inverse }
    }

    /// The exact GELU `transformers` uses for "gelu": x · Φ(x), with the error function.
    private static func gelu(_ values: inout [Float]) {
        for index in values.indices {
            let x = values[index]
            values[index] = 0.5 * x * (1 + Foundation.erf(x / Float(2).squareRoot()))
        }
    }
}
