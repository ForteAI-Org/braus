import Foundation
import PerceptionCore

/// SensitivityClassifier owns local privacy classification and creates guards for value readers.
/// Rules and compiled expressions are immutable and shared safely between concurrent reads.
public struct SensitivityClassifier: Sendable {
    private let rules: SensitivityRules
    private let strongPatterns: [NSRegularExpression]
    private let declaredPattern: NSRegularExpression?
    private static let editableRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let cardPattern = expression(#"(?<![A-Za-z0-9])(?:[0-9][ -]?){11,18}[0-9](?![A-Za-z0-9])"#)
    private static let ibanPattern = expression(#"(?i)\b[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]){11,30}\b"#)

    private static let bundledStrongPatterns = SensitivityRules.bundled.strongPatterns.map(expression)
    private static let bundledDeclaredPattern = makeDeclaredPattern(SensitivityRules.bundled.decisiveLabels)

    public init(rules: SensitivityRules = .bundled) {
        self.rules = rules
        strongPatterns = rules.strongPatterns == SensitivityRules.bundled.strongPatterns
            ? Self.bundledStrongPatterns : rules.strongPatterns.map(Self.expression)
        declaredPattern = rules.decisiveLabels == SensitivityRules.bundled.decisiveLabels
            ? Self.bundledDeclaredPattern : Self.makeDeclaredPattern(rules.decisiveLabels)
    }

    private static func makeDeclaredPattern(_ labels: [String]) -> NSRegularExpression? {
        guard !labels.isEmpty else { return nil }
        let alternatives = labels.sorted { $0.count > $1.count }.map { label in
            let words = label.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            return words.joined(separator: #"[\s'’-]+"#)
        }.joined(separator: "|")
        return expression(#"(?i)(?=\b(?:"# + alternatives + #")\b(?:\s*(?::|=|is\b|è\b)\s*|\s+)["']?([^\s"',;]+))"#)
    }

    /// Classifies a value with field signals, using a secret threshold of three.
    public func classify(_ value: String?, in field: FieldSignals) -> SensitivityVerdict {
        var score = 0
        var reasons: [SensitivityReason] = []
        func add(_ points: Int, _ reason: SensitivityReason) { score += points; reasons.append(reason) }
        if field.role == "AXSecureTextField" || field.subrole == "AXSecureTextField" { add(3, .secureRole) }
        if let role = field.role, Self.editableRoles.contains(role), field.subrole == nil {
            add(3, .unreadableSubrole)
        }
        if field.markupDeclaresSecret { add(3, .secureMarkup) }
        if field.declaredSecret { add(3, .declared) }
        if field.labels.contains(where: namesSecret) { add(3, .decisiveLabel) }
        if field.labels.contains(where: { matchesLabel($0, names: rules.weakLabels) }) { add(1, .weakLabel) }
        let shapes = (field.labels + [value].compactMap { $0 }).flatMap { shapeFindings(in: $0) }
        if shapes.contains(where: { $0.verdict.reasons.contains(.strongShape) }) { add(3, .strongShape) }
        if shapes.contains(where: { $0.verdict.reasons.contains(.checksum) }) { add(3, .checksum) }
        if let value {
            let isShortCode = (4...8).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
            if isShortCode || Self.isRandomShape(value) { add(2, .randomShape) }
        }
        if field.isContent { reasons.append(.contentSurface) }
        return .init(sensitivity: score >= 3 ? .secret : field.isContent ? .personal : .ordinary,
                     score: score, reasons: reasons)
    }

    /// Supplies the before-read and after-read decisions without retaining field values.
    public var valueGuard: ValueGuard {
        ValueGuard(
            refusesLabel: { namesSecret($0) },
            withholdsValue: { classify($0, in: .init(labels: $1)).sensitivity == .secret }
        )
    }

    /// Returns nonoverlapping sensitive spans, retaining indices into the supplied text.
    public func findings(in text: String, field: FieldSignals) -> [SensitivityFinding] {
        let verdict = classify(nil, in: field)
        if verdict.sensitivity == .secret, !text.isEmpty {
            return [.init(range: text.startIndex..<text.endIndex, verdict: verdict)]
        }
        if verdict.reasons.contains(.weakLabel) {
            let combined = classify(text, in: field)
            if combined.sensitivity == .secret, !text.isEmpty {
                return [.init(range: text.startIndex..<text.endIndex, verdict: combined)]
            }
        }
        var found = shapeFindings(in: text)
        let whole = NSRange(text.startIndex..., in: text)
        if let declaredPattern {
            for match in declaredPattern.matches(in: text, range: whole) {
                if let range = Range(match.range(at: 1), in: text) {
                    found.append(.init(range: range, verdict: .init(sensitivity: .secret, score: 3,
                                                                  reasons: [.decisiveLabel])))
                }
            }
        }
        var merged: [SensitivityFinding] = []
        for finding in found.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = merged.last, finding.range.lowerBound < last.range.upperBound {
                merged[merged.count - 1] = .init(range: last.range.lowerBound..<max(last.range.upperBound, finding.range.upperBound),
                                               verdict: last.verdict)
            } else { merged.append(finding) }
        }
        guard verdict.sensitivity == .personal else { return merged }
        var personal: [SensitivityFinding] = []
        var start = text.startIndex
        for finding in merged {
            if start < finding.range.lowerBound {
                personal.append(.init(range: start..<finding.range.lowerBound, verdict: verdict))
            }
            personal.append(finding)
            start = finding.range.upperBound
        }
        if start < text.endIndex { personal.append(.init(range: start..<text.endIndex, verdict: verdict)) }
        return personal
    }

    private func namesSecret(_ label: String) -> Bool { matchesLabel(label, names: rules.decisiveLabels) }

    private func matchesLabel(_ label: String, names: [String]) -> Bool {
        let words = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let joined = " " + words.joined(separator: " ") + " "
        return names.contains { $0.contains(" ") ? joined.contains($0) : words.contains($0) }
    }

    private func shapeFindings(in text: String) -> [SensitivityFinding] {
        // Cards need twelve digits; generated path components need at least twelve characters.
        guard text.utf8.count >= 12 else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var found: [SensitivityFinding] = []
        func add(_ range: Range<String.Index>, _ reason: SensitivityReason) {
            found.append(.init(range: range, verdict: .init(sensitivity: .secret, score: 3, reasons: [reason])))
        }
        for pattern in strongPatterns {
            for match in pattern.matches(in: text, range: whole) {
                if let range = Range(match.range, in: text) { add(range, .strongShape) }
            }
        }
        var digitCount = 0
        var isASCII = true
        for byte in text.utf8 {
            if (48...57).contains(byte) { digitCount += 1 }
            if byte >= 128 { isASCII = false }
        }
        if isASCII {
            for token in text.utf8.split(whereSeparator: { $0 == 32 || (9...13).contains($0) })
                where token.count >= 12 {
                let range = token.startIndex..<token.endIndex
                if Self.looksGenerated(String(text[range])) { add(range, .strongShape) }
            }
        } else {
            for token in text.split(whereSeparator: \.isWhitespace)
                where token.utf8.count >= 12 && Self.looksGenerated(String(token)) {
                add(token.startIndex..<token.endIndex, .strongShape)
            }
        }
        if rules.luhn, digitCount >= 12 {
            for match in Self.cardPattern.matches(in: text, range: whole) {
                if let range = Range(match.range, in: text), Checksums.luhn(String(text[range])) {
                    add(range, .checksum)
                }
            }
        }
        if rules.iban, digitCount >= 2 {
            for match in Self.ibanPattern.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                // A following word can share the alphabet; retain the last checksum-valid word boundary.
                let ends = [range.upperBound] + text[range].indices.reversed().filter { text[$0].isWhitespace }
                for end in ends where Checksums.iban(String(text[range.lowerBound..<end])) {
                    add(range.lowerBound..<end, .checksum)
                    break
                }
            }
        }
        return found
    }

    private static func isRandomShape(_ value: String) -> Bool {
        guard (12...31).contains(value.count), !value.contains(where: \.isWhitespace) else { return false }
        let classes = [value.contains(where: \.isUppercase), value.contains(where: \.isLowercase),
                       value.contains(where: \.isNumber), value.contains { !$0.isLetter && !$0.isNumber }]
        return classes.filter { $0 }.count >= 3
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) }
        catch { preconditionFailure("Invalid sensitivity expression: \(error)") }
    }
}
