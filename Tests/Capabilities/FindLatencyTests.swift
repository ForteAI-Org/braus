import Testing

@Suite
struct FindLatencyTests {
    @Test(.enabled(if: FindEvaluation.hasModels, "BRAUS_RECALL_MODELS is required for warm query timings"))
    func warmQueriesIncludeEmbedding() async throws {
        let report = try await FindEvaluation.result.value
        #expect(report.warm_query_count == 200)
        #expect(report.latency_ms.count == 200)
        #expect(report.latency_ms.sorted()[189] <= 30)
        #expect(!report.hardware.isEmpty)
    }
}
