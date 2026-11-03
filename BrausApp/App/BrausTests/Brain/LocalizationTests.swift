import Foundation
import Testing

@Suite("Brain localization")
struct LocalizationTests {
    @Test func italianIsBundled() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Braus.xcodeproj/project.pbxproj")
        let source = try String(contentsOf: project, encoding: .utf8)
        let start = try #require(source.range(of: "knownRegions = ("))
        let end = try #require(source.range(of: ");", range: start.upperBound..<source.endIndex))
        let regions = source[start.upperBound..<end.lowerBound].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(regions.contains("it"))
    }

    @Test func brainStringsInCatalog() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Braus")
        let data = try Data(contentsOf: app.appendingPathComponent("Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "en")
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        let folder = app.appendingPathComponent("Views/Settings/Brain")
        let expression = try NSRegularExpression(pattern: #"String\(localized: "((?:\\.|[^"\\])*)""#)
        let untranslated = try NSRegularExpression(
            pattern: #"(?:Text|Label|Section|Picker|ContentUnavailableView|navigationTitle|help|accessibilityLabel|accessibilityValue)\(\s*""#
        )
        for (key, entry) in strings {
            let locales = try #require(entry["localizations"] as? [String: [String: Any]])
            for language in ["en", "it"] {
                let unit = try #require(locales[language]?["stringUnit"] as? [String: String])
                #expect(unit["state"] == "translated", "Untranslated \(language): \(key)")
                #expect(unit["value"]?.isEmpty == false)
            }
        }
        var count = 0
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(untranslated.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) == 0,
                    "User-facing literal bypasses the catalog: \(file.lastPathComponent)")
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try #require(Range(match.range(at: 1), in: source))
                let literal = String(source[range])
                var key = literal.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "%@", options: .regularExpression)
                if literal.contains("\\(value)") || literal.contains("simulation.physics") {
                    key = key.replacingOccurrences(of: "%@", with: "%lld", range: key.range(of: "%@"))
                } else if literal.contains("status.") && !literal.contains("status.path") {
                    key = key.replacingOccurrences(of: "%@", with: "%lld")
                }
                let entry = try #require(strings[key], "Missing catalog key: \(key)")
                let locales = try #require(entry["localizations"] as? [String: Any])
                #expect(locales["it"] != nil, "Missing Italian: \(key)")
                count += 1
            }
        }
        #expect(count > 20)
    }
}
