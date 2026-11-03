import Testing

@Suite
struct FindOfflineQualityTests {
    @Test func tuningOnlyLeavesTheExistingVerificationGateUnchangedByDefault() {
        for tuningPasses in [false, true] {
            for usesProductionSettings in [false, true] {
                #expect(FindEvaluation.permitsVerification(tuningPasses: tuningPasses,
                    usesProductionSettings: usesProductionSettings) == (tuningPasses && usesProductionSettings))
                #expect(!FindEvaluation.permitsVerification(tuningOnly: true, tuningPasses: tuningPasses,
                    usesProductionSettings: usesProductionSettings))
            }
        }
    }

    @Test func fixtureIsBalancedDisjointAndComplete() throws {
        let fixture = try FindEvaluation.fixture()
        #expect(fixture.questions.count == 150)
        #expect(Set(fixture.questions.map(\.query)).count == 150)
        #expect(fixture.questions.filter { $0.language == "en" }.count == 75)
        #expect(fixture.questions.filter { $0.language == "it" }.count == 75)
        for split in ["tuning", "verification"] {
            #expect(fixture.questions.filter { $0.split == split }.count == 75)
            #expect(fixture.questions.filter { $0.split == split && $0.expected == "none" }.count == 15)
        }
        let identifiers = Set(fixture.entries.map(\.id)).union(["none"])
        #expect(fixture.questions.allSatisfy { identifiers.contains($0.expected) })
        let examples = Set(fixture.entries.flatMap(\.examples))
        #expect(fixture.questions.allSatisfy { !examples.contains($0.query) })
    }

    @Test(.enabled(if: FindEvaluation.hasModels, "BRAUS_RECALL_MODELS is required for Granite quality"))
    func tuningQuality() async throws {
        let report = try await FindEvaluation.result.value
        #expect(report.tuning_top3_hits >= 57)
        #expect(report.tuning_none_hits >= 14)
    }

    @Test(.enabled(if: FindEvaluation.hasModels && FindEvaluation.verifies,
                   "BRAUS_RECALL_MODELS is required; BRAUS_FIND_TUNING_ONLY must be unset for verification"))
    func verificationQuality() async throws {
        let report = try await FindEvaluation.result.value
        try #require(report.verification_count == 75,
            "Verification withheld: tuning top3 \(report.tuning_top3_hits)/60, none \(report.tuning_none_hits)/15; settings must pass tuning before verification")
        #expect(Double(report.top3_hits) / Double(report.verification_count - report.none_count) >= 0.95)
        #expect(Double(report.none_hits) / Double(report.none_count) >= 0.90)
    }
}
