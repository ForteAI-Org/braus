import Capabilities
import Foundation
import LocalMCP
import Testing

@Suite
struct CapabilitySearchTests {
    @Test func scoresMatchTheSpecifiedFormula() async throws {
        let search = CapabilitySearch(entries: [
            searchEntry("alpha", description: "alpha beta"),
            searchEntry("beta")
        ])
        let hits = await search.search("alpha", limit: 5)
        let hit = try #require(hits.first)
        let expected = log(2.0) * (2 * 1.9) / (2 + 0.9 * (0.6 + 0.4 * 3 / 2))
        #expect(hit.id.rawValue == "alpha")
        #expect(abs(hit.score - expected) < 0.000000000001)
        #expect(hits.count == 1)
        #expect(await search.search("alpha alpha", limit: 5) == hits)
        let common = await search.search("beta", limit: 5)
        #expect(common.map(\.id.rawValue) == ["beta", "alpha"])
        let commonHit = try #require(common.first)
        let commonExpected = log(1.2) * 1.9 / (1 + 0.9 * (0.6 + 0.4 / 2))
        #expect(abs(commonHit.score - commonExpected) < 0.000000000001)
    }

    @Test func bilingualExamplesFindScrollAmongTheFirstThree() async {
        let search = CapabilitySearch(entries: [
            searchEntry("scroll", group: "interaction", description: "Move through content.",
                        examples: ["Scroll down the list", "Scorri la lista"]),
            searchEntry("select", description: "Select an item in a list"),
            searchEntry("status", description: "Read current status"),
            searchEntry("windows", description: "List windows")
        ])
        for query in ["scroll down the list", "scorri la lista"] {
            #expect(await search.search(query, limit: 3).contains { $0.id.rawValue == "scroll" })
        }
    }

    @Test func normalizesUnicodeCaseAndSeparatorsWithoutStemming() async {
        let search = CapabilitySearch(entries: [searchEntry("CAFÉ_scroll", description: "item42")])
        #expect(await search.search("cafe\u{301} SCROLL", limit: 5).count == 1)
        #expect(await search.search("item42", limit: 5).count == 1)
        #expect(await search.search("scrolling", limit: 5).isEmpty)
    }

    @Test func indexesEverySpecifiedFieldWithEqualWeight() async throws {
        let search = CapabilitySearch(entries: [searchEntry(
            "alpha", group: "beta", description: "gamma",
            properties: ["delta": .object(["description": .string("hidden")])], examples: ["epsilon"]
        )])
        var scores: [Double] = []
        for word in ["alpha", "beta", "gamma", "delta", "epsilon"] {
            scores.append(try #require(await search.search(word, limit: 5).first).score)
        }
        #expect(Set(scores).count == 1)
        #expect(await search.search("hidden", limit: 5).isEmpty)
    }

    @Test func emptyUnknownAndStopwordQueriesHaveNoHits() async {
        let search = CapabilitySearch(entries: [searchEntry("scroll", examples: ["Scorri la lista"])])
        let english = "a an and are as at be by for from in is it of on or that the this to with"
        let italian = "a al alla alle con da dal della delle di e gli i il in la le lo o per su un una uno"
        let stopwordsOnly = CapabilitySearch(entries: [searchEntry("the", description: english + " " + italian)])
        #expect(await stopwordsOnly.search(english + " " + italian, limit: 5).isEmpty)
        for query in ["", "?!", "unrelated", english, italian] {
            #expect(await search.search(query, limit: 5).isEmpty)
        }
        #expect(await CapabilitySearch(entries: []).search("scroll", limit: 5).isEmpty)
        #expect(await CapabilitySearch(entries: [searchEntry("the")]).search("the", limit: 5).isEmpty)
    }

    @Test func scoresBelowTheThresholdAreExcluded() async {
        let entries = (0..<100).map { searchEntry("entry\($0)", description: "shared") }
        #expect(await CapabilitySearch(entries: entries).search("shared", limit: 5).isEmpty)
    }

    @Test func tieOrderLimitsAndInputOrderAreStable() async {
        let entries = ["zeta", "beta", "alpha", "gamma", "delta", "epsilon"].map {
            searchEntry($0, description: "shared")
        }
        let search = CapabilitySearch(entries: entries)
        let hits = await search.search("shared", limit: Int.max)
        #expect(hits.map(\.id.rawValue) == ["alpha", "beta", "delta", "epsilon", "gamma"])
        #expect(hits.allSatisfy { $0.score >= CapabilitySearch.minimumScore })
        #expect(CapabilitySearch.maximumHits == 5)
        #expect(CapabilitySearch.minimumScore == 0.01)
        #expect(await CapabilitySearch(entries: entries.reversed()).search("shared", limit: 5) == hits)
        #expect(await search.search("shared", limit: 2) == Array(hits.prefix(2)))
        #expect(await search.search("shared", limit: 0).isEmpty)
        #expect(await search.search("shared", limit: -1).isEmpty)
    }
}
