//
//  UnigramTokenizer.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// UnigramTokenizer reproduces the XLM-RoBERTa tokenizer the way `transformers` 5 builds it for
/// `XLMRobertaTokenizer` over a model's vocabulary and SentencePiece normalization map: special tokens matched
/// in the raw text, the map applied (`Precompiled`), the text split at whitespace, `▁` in front of each word
/// and a word at each `▁` (Metaspace), then the Unigram model's best segmentation of each word, consecutive
/// unknowns fused, and `<s> … </s>` around the result. That is how SentencePiece tokenized the models' training
/// text. The `tokenizer.json` these models ship serializes an older fast pipeline (runs of spaces collapsed, no
/// split at whitespace) that keeps a `▁` token for trailing whitespace; `transformers` 5 does not, and neither
/// does this runtime. Its output is checked token for token against `transformers` on a fixed set of texts
/// (`LocalEmbeddingTests`); a vocabulary or normalizer it does not implement is refused at load, never
/// approximated. Immutable after init.
struct UnigramTokenizer: Sendable {

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case unsupported(String)

        var description: String {
            switch self {
                case .unreadable(let why): "the tokenizer cannot be read: \(why)"
                case .unsupported(let what): "the tokenizer uses \(what), which this runtime does not implement"
            }
        }
    }

    /// Encoding is what one text became: its ids with the special tokens, and whether it was cut to fit.
    struct Encoding: Equatable {
        let ids: [Int]
        let isTruncated: Bool
    }

    private let pieces: [String: (id: Int, score: Double)]
    private let longestPiece: Int
    private let unknownID: Int
    private let unknownScore: Double
    private let beginID: Int
    private let endID: Int
    /// The special tokens matched in the raw text, longest first, with whether whitespace on their left is theirs.
    private let specials: [(content: String, id: Int, stripsLeft: Bool)]
    private let normalizer: PrecompiledNormalizer

    init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        guard let model = root["model"] as? [String: Any], model["type"] as? String == "Unigram",
              let vocab = model["vocab"] as? [[Any]], let unknown = model["unk_id"] as? Int else {
            throw Failure.unsupported("a model other than Unigram")
        }
        if let fallback = model["byte_fallback"] as? Bool, fallback { throw Failure.unsupported("byte fallback") }
        guard let normalizer = root["normalizer"] as? [String: Any], normalizer["type"] as? String == "Sequence",
              let steps = normalizer["normalizers"] as? [[String: Any]], steps.count == 2,
              steps[0]["type"] as? String == "Precompiled", let charsmap = steps[0]["precompiled_charsmap"] as? String,
              steps[1]["type"] as? String == "Replace", (steps[1]["pattern"] as? [String: Any])?["Regex"] as? String == " {2,}",
              steps[1]["content"] as? String == " " else {
            throw Failure.unsupported("a normalizer other than Precompiled then collapsed spaces")
        }
        guard let pre = root["pre_tokenizer"] as? [String: Any], pre["type"] as? String == "Metaspace",
              pre["replacement"] as? String == "\u{2581}" else {
            throw Failure.unsupported("a pre-tokenizer other than Metaspace")
        }
        guard let decoded = Data(base64Encoded: charsmap) else { throw Failure.unreadable("precompiled_charsmap") }
        var table: [String: (Int, Double)] = [:]
        table.reserveCapacity(vocab.count)
        var longest = 1
        var lowest = Double.greatestFiniteMagnitude
        for (id, entry) in vocab.enumerated() {
            guard entry.count == 2, let piece = entry[0] as? String, let score = (entry[1] as? NSNumber)?.doubleValue else {
                throw Failure.unreadable("vocabulary entry \(id)")
            }
            if table[piece] == nil { table[piece] = (id, score) }
            longest = max(longest, piece.unicodeScalars.count)
            lowest = min(lowest, score)
        }
        var specials: [(String, Int, Bool)] = []
        for added in root["added_tokens"] as? [[String: Any]] ?? [] where added["special"] as? Bool == true {
            guard let content = added["content"] as? String, let id = added["id"] as? Int else { continue }
            specials.append((content, id, added["lstrip"] as? Bool ?? false))
        }
        guard let begin = table["<s>"]?.0, let end = table["</s>"]?.0 else { throw Failure.unsupported("no <s> and </s>") }
        self.pieces       = table
        self.longestPiece = longest
        self.unknownID    = unknown
        self.unknownScore = lowest - 10
        self.beginID      = begin
        self.endID        = end
        self.specials     = specials.sorted { $0.0.count > $1.0.count }.map { (content: $0.0, id: $0.1, stripsLeft: $0.2) }
        self.normalizer   = try PrecompiledNormalizer(decoded)
    }

    /// The ids of `text` with `<s>` and `</s>`, at most `maximumTokens` in all: a longer text keeps its first
    /// tokens and says it was cut.
    func encode(_ text: String, maximumTokens: Int) -> Encoding {
        var ids: [Int] = []
        for segment in split(text) {
            switch segment {
                case .special(let id): ids.append(id)
                case .text(let raw): ids += tokens(of: raw)
            }
        }
        let room = max(0, maximumTokens - 2)
        let isTruncated = ids.count > room
        if isTruncated { ids.removeSubrange(room...) }
        return Encoding(ids: [beginID] + ids + [endID], isTruncated: isTruncated)
    }

    private enum Segment {
        case text(String)
        case special(Int)
    }

    /// The raw text cut around the special tokens it contains, as the added vocabulary matches them.
    private func split(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var earliest: (range: Range<Substring.Index>, id: Int, stripsLeft: Bool)?
            for special in specials {
                if let range = rest.range(of: special.content), earliest.map({ range.lowerBound < $0.range.lowerBound }) ?? true {
                    earliest = (range, special.id, special.stripsLeft)
                }
            }
            guard let match = earliest else {
                segments.append(.text(String(rest)))
                break
            }
            var before = rest[rest.startIndex..<match.range.lowerBound]
            if match.stripsLeft { while before.last?.isWhitespace == true { before = before.dropLast() } }
            if !before.isEmpty { segments.append(.text(String(before))) }
            segments.append(.special(match.id))
            rest = rest[match.range.upperBound...]
        }
        return segments
    }

    /// The model's ids of a text without special tokens: normalized, split at whitespace, each part given its
    /// `▁` and cut again at every `▁` it holds, each word segmented by the Unigram model, consecutive unknowns
    /// fused into one.
    private func tokens(of raw: String) -> [Int] {
        let normalized = normalizer.normalize(raw)
        var ids: [Int] = []
        var word: [Unicode.Scalar] = []
        func flush() {
            guard !word.isEmpty else { return }
            for id in segment(word) where !(id == unknownID && ids.last == unknownID) { ids.append(id) }
            word.removeAll(keepingCapacity: true)
        }
        var part: [Unicode.Scalar] = []
        func metaspace() {
            guard !part.isEmpty else { return }
            if part.first != "\u{2581}" { part.insert("\u{2581}", at: 0) }
            for scalar in part {
                if scalar == "\u{2581}" { flush() }
                word.append(scalar)
            }
            flush()
            part.removeAll(keepingCapacity: true)
        }
        for scalar in normalized.unicodeScalars {
            if scalar.properties.isWhitespace { metaspace() } else { part.append(scalar) }
        }
        metaspace()
        return ids
    }

    /// The best segmentation of one word: the Viterbi path through every vocabulary piece that matches, with
    /// an unknown of one scalar wherever no piece of one scalar starts.
    private func segment(_ scalars: [Unicode.Scalar]) -> [Int] {
        let count = scalars.count
        var best = [Double](repeating: -.infinity, count: count + 1)
        var back = [(start: Int, id: Int)](repeating: (0, 0), count: count + 1)
        best[0] = 0
        for start in 0..<count where best[start] > -.infinity {
            var hasSingle = false
            var piece = String.UnicodeScalarView()
            for end in (start + 1)...min(count, start + longestPiece) {
                piece.append(scalars[end - 1])
                guard let found = pieces[String(piece)] else { continue }
                if end == start + 1 { hasSingle = true }
                let score = best[start] + found.score
                if score > best[end] {
                    best[end] = score
                    back[end] = (start, found.id)
                }
            }
            if !hasSingle {
                let score = best[start] + unknownScore
                if score > best[start + 1] {
                    best[start + 1] = score
                    back[start + 1] = (start, unknownID)
                }
            }
        }
        var ids: [Int] = []
        var position = count
        while position > 0 {
            ids.append(back[position].id)
            position = back[position].start
        }
        return ids.reversed()
    }
}

/// PrecompiledNormalizer applies a SentencePiece `precompiled_charsmap`: a Darts double-array trie over UTF-8
/// bytes whose leaves point into a pool of null-terminated replacement strings. It follows `spm_precompiled`,
/// the code `tokenizers` runs: each grapheme shorter than six bytes is replaced whole by the replacement of its
/// shortest matching prefix; otherwise each of its scalars is replaced alone, or kept.
struct PrecompiledNormalizer: Sendable {

    private let units: [UInt32]
    private let pool: [UInt8]

    init(_ data: Data) throws {
        guard data.count >= 4 else { throw UnigramTokenizer.Failure.unreadable("precompiled_charsmap is too short") }
        let bytes = [UInt8](data)
        let trieSize = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        guard trieSize % 4 == 0, 4 + trieSize <= bytes.count else {
            throw UnigramTokenizer.Failure.unreadable("precompiled_charsmap's trie size")
        }
        var units = [UInt32](repeating: 0, count: trieSize / 4)
        for index in units.indices {
            let at = 4 + index * 4
            units[index] = UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        self.units = units
        self.pool  = Array(bytes[(4 + trieSize)...])
    }

    func normalize(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        for grapheme in text {
            let bytes = Array(String(grapheme).utf8)
            if bytes.count < 6, let replacement = transform(bytes) {
                output.append(contentsOf: replacement.unicodeScalars)
                continue
            }
            for scalar in grapheme.unicodeScalars {
                if let replacement = transform(Array(String(scalar).utf8)) {
                    output.append(contentsOf: replacement.unicodeScalars)
                } else {
                    output.append(scalar)
                }
            }
        }
        return String(output)
    }

    /// The replacement of the shortest prefix of `key` the trie holds, or nil.
    private func transform(_ key: [UInt8]) -> String? {
        guard let first = commonPrefixSearch(key).first, first < pool.count else { return nil }
        var end = first
        while end < pool.count, pool[end] != 0 { end += 1 }
        return String(decoding: pool[first..<end], as: UTF8.self)
    }

    private func commonPrefixSearch(_ key: [UInt8]) -> [Int] {
        guard !units.isEmpty else { return [] }
        var results: [Int] = []
        var position = Int(Self.offset(units[0]))
        for byte in key {
            if byte == 0 { break }
            position ^= Int(byte)
            guard position < units.count else { return results }
            let unit = units[position]
            if Self.label(unit) != UInt32(byte) { return results }
            position ^= Int(Self.offset(unit))
            if Self.hasLeaf(unit), position < units.count { results.append(Int(Self.value(units[position]))) }
        }
        return results
    }

    private static func hasLeaf(_ unit: UInt32) -> Bool { (unit >> 8) & 1 == 1 }
    private static func value(_ unit: UInt32) -> UInt32 { unit & ((1 << 31) - 1) }
    private static func label(_ unit: UInt32) -> UInt32 { unit & ((1 << 31) | 0xFF) }
    private static func offset(_ unit: UInt32) -> UInt32 { (unit >> 10) << ((unit & (1 << 9)) >> 6) }
}
