//
//  TelemetryTests.swift
//  Braus
//
//  Created by Ronaldo Zefi on 26/10/2026.
//

import Foundation
import Synchronization
import Testing
@testable import Telemetry

@Suite("Telemetry: when it sends, what it records and the OTLP body", .serialized)
struct TelemetryTests {

    // MARK: Whether to send

    @Test("on by default; off by DO_NOT_TRACK, BRAUS_TELEMETRY or the person's choice")
    func enabled() {
        #expect(TelemetryConfiguration.isEnabled(environment: [:], stored: nil))
        #expect(TelemetryConfiguration.isEnabled(environment: [:], stored: true))
        #expect(!TelemetryConfiguration.isEnabled(environment: [:], stored: false))
        for value in ["1", "true", "yes"] {
            #expect(!TelemetryConfiguration.isEnabled(environment: ["DO_NOT_TRACK": value], stored: true))
        }
        for value in ["0", "false", ""] {
            #expect(TelemetryConfiguration.isEnabled(environment: ["DO_NOT_TRACK": value], stored: nil))
        }
        for value in ["0", "false", "OFF", "no"] {
            #expect(!TelemetryConfiguration.isEnabled(environment: ["BRAUS_TELEMETRY": value], stored: true))
        }
        #expect(TelemetryConfiguration.isEnabled(environment: ["BRAUS_TELEMETRY": "1"], stored: nil))
        #expect(TelemetryConfiguration.isDisabledByEnvironment(["DO_NOT_TRACK": "1"]))
        #expect(!TelemetryConfiguration.isDisabledByEnvironment([:]))
    }

    @Test("the endpoint the environment names, when it is an http or https URL")
    func endpoint() {
        #expect(TelemetryConfiguration.endpoint(in: [:]) == TelemetryConfiguration.defaultEndpoint)
        #expect(TelemetryConfiguration.endpoint(in: ["BRAUS_TELEMETRY_ENDPOINT": "http://localhost:4318"]).absoluteString
            == "http://localhost:4318")
        #expect(TelemetryConfiguration.endpoint(in: ["BRAUS_TELEMETRY_ENDPOINT": "file:///etc/passwd"])
            == TelemetryConfiguration.defaultEndpoint)
    }

    @Test("the installation ID is made once, random, and kept")
    func installationID() throws {
        let defaults = try #require(UserDefaults(suiteName: "braus-telemetry-\(UUID().uuidString)"))
        let first    = TelemetryConfiguration.installationID(in: defaults)
        #expect(UUID(uuidString: first) != nil)
        #expect(TelemetryConfiguration.installationID(in: defaults) == first)
        defaults.set("not-an-id", forKey: TelemetryConfiguration.installationIDKey)
        #expect(TelemetryConfiguration.installationID(in: defaults) != "not-an-id")
    }

    // MARK: What is recorded

    @Test("a recorder that is not recording drops every value; stop forgets the totals")
    func recordingWindow() {
        let recorder = TelemetryRecorder()
        let series   = TelemetryRecorder.Series("c", ["a": "1"])
        recorder.add(to: series)
        #expect(recorder.snapshot() == nil)
        recorder.start(at: Date(timeIntervalSince1970: 10))
        recorder.add(to: series)
        recorder.add(2, to: series)
        recorder.record(0.3, in: .init("h", [:]), bounds: [0.1, 0.5])
        recorder.record(7, in: .init("h", [:]), bounds: [0.1, 0.5])
        let snapshot = recorder.snapshot(at: Date(timeIntervalSince1970: 20))
        #expect(snapshot?.counters[series] == 3)
        #expect(snapshot?.histograms[.init("h", [:])]?.bucketCounts == [0, 1, 1])
        #expect(snapshot?.histograms[.init("h", [:])]?.sum == 7.3)
        recorder.stop()
        #expect(recorder.snapshot() == nil)
    }

    @Test("only a tool's own name, a known outcome and a known provider are kept")
    func boundedValues() {
        #expect(Telemetry.toolName("open_session") == "open_session")
        for unsafe in ["/Users/ron/secret.txt", "Mail", "type text", "", String(repeating: "a", count: 49)] {
            #expect(Telemetry.toolName(unsafe) == "other")
        }
        #expect(Telemetry.outcome(inAnswerText: #"{"scene":"…","status":"found_acted"}"#, isError: false) == "found_acted")
        #expect(Telemetry.outcome(inAnswerText: #"{"result":{"outcome":"acted_unverified"}}"#, isError: false)
            == "acted_unverified")
        #expect(Telemetry.outcome(inAnswerText: #"{"status":"candidate"}"#, isError: false) == "ok")
        #expect(Telemetry.outcome(inAnswerText: "plain text", isError: true) == "error")
        #expect(Telemetry.outcome(inAnswerText: nil, isError: false) == "ok")
    }

    // MARK: The OTLP body

    @Test("the body is cumulative OTLP JSON: the resource, the sums, the histograms and the up gauge")
    func body() throws {
        let recorder = TelemetryRecorder()
        recorder.start(at: Date(timeIntervalSince1970: 100))
        recorder.add(to: .init(TelemetryMetric.toolCalls, ["tool": "click", "outcome": "found_acted"]))
        recorder.record(0.2, in: .init(TelemetryMetric.toolDuration, ["tool": "click"]), bounds: TelemetryMetric.toolBounds)
        let snapshot = try #require(recorder.snapshot(at: Date(timeIntervalSince1970: 160)))
        let configuration = TelemetryConfiguration(installationID: "abc", appVersion: "1.2.0", osVersion: "26.0.0",
                                                   architecture: "arm64")
        let data = OTLPMetrics.body(snapshot, configuration: configuration)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resource = try #require((json["resourceMetrics"] as? [[String: Any]])?.first)
        let attributes = (resource["resource"] as? [String: Any])?["attributes"] as? [[String: Any]] ?? []
        let values = Dictionary(uniqueKeysWithValues: attributes.map {
            ($0["key"] as? String ?? "", ($0["value"] as? [String: Any])?["stringValue"] as? String ?? "")
        })
        #expect(values == ["service.name": "braus", "service.version": "1.2.0", "service.instance.id": "abc",
                           "os.type": "darwin", "os.version": "26.0.0", "host.arch": "arm64"])

        let metrics = ((resource["scopeMetrics"] as? [[String: Any]])?.first?["metrics"] as? [[String: Any]]) ?? []
        #expect(metrics.map { $0["name"] as? String } == [TelemetryMetric.toolCalls, TelemetryMetric.toolDuration,
                                                           TelemetryMetric.appUp])
        let sum   = try #require(metrics[0]["sum"] as? [String: Any])
        let point = try #require((sum["dataPoints"] as? [[String: Any]])?.first)
        #expect(sum["aggregationTemporality"] as? Int == 2 && sum["isMonotonic"] as? Bool == true)
        #expect(point["asInt"] as? String == "1")
        #expect(point["startTimeUnixNano"] as? String == "100000000000")
        #expect(point["timeUnixNano"] as? String == "160000000000")
        let histogram = try #require((metrics[1]["histogram"] as? [String: Any])?["dataPoints"] as? [[String: Any]])
        #expect(histogram.first?["count"] as? String == "1")
        #expect((histogram.first?["bucketCounts"] as? [String])?.count == TelemetryMetric.toolBounds.count + 1)
        #expect(metrics[1]["unit"] as? String == "s")
    }

    // MARK: Sending

    @Test("an export posts the body to <endpoint>/v1/metrics as JSON; a failure is dropped")
    func export() async throws {
        let recorder = TelemetryRecorder()
        recorder.start()
        recorder.add(to: .init(TelemetryMetric.toolCalls, ["tool": "click", "outcome": "ok"]))
        let snapshot = try #require(recorder.snapshot())
        let configuration = TelemetryConfiguration(endpoint: URL(string: "http://localhost:4318")!,
                                                   installationID: "abc", appVersion: "1.0")
        let sent = Mutex<[URLRequest]>([])
        await Telemetry.export(snapshot, configuration: configuration) { request in sent.withLock { $0.append(request) } }
        let request = try #require(sent.withLock { $0.first })
        #expect(request.url?.absoluteString == "http://localhost:4318/v1/metrics")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect((request.httpBody?.count ?? 0) > 0)

        await Telemetry.export(snapshot, configuration: configuration) { _ in throw URLError(.notConnectedToInternet) }
    }

    @Test("nothing is recorded through the facade before start")
    func facadeIdleUntilStarted() {
        #expect(!Telemetry.isRunning)
        Telemetry.toolCall("click", outcome: "found_acted", seconds: 0.1)
        Telemetry.turn(provider: "codex", ending: "completed", seconds: 3)
        #expect(Telemetry.recorder.snapshot() == nil)
    }
}
