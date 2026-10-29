//
//  OTLPMetrics.swift
//  Braus
//
//  Created by Ronaldo Zefi on 26/10/2026.
//

import Foundation

/// OTLPMetrics writes a snapshot as the body of an OTLP/HTTP metrics export in its JSON encoding
/// (`POST /v1/metrics`, `application/json`): one resource for this installation, one scope, a cumulative sum
/// per counter, a cumulative histogram per histogram and the `braus.app.up` gauge, which says the app ran in
/// the interval even when it made no call. Integers are strings and times are nanoseconds since 1970, as the
/// protocol's JSON mapping asks. Pure: the same snapshot and configuration write the same bytes.
public enum OTLPMetrics {

    /// The protocol's value for cumulative temporality.
    static let cumulative = 2

    /// The units of the metrics Braus sends, by name; a metric not listed has none.
    static let units: [String: String] = [
        TelemetryMetric.toolCalls   : "{call}",
        TelemetryMetric.toolDuration: "s",
        TelemetryMetric.turns       : "{turn}",
        TelemetryMetric.turnDuration: "s",
    ]

    public static func body(_ snapshot: TelemetryRecorder.Snapshot, configuration: TelemetryConfiguration) -> Data {
        let start = nanoseconds(snapshot.start)
        let time  = nanoseconds(snapshot.time)

        var metrics: [[String: Any]] = []
        let counters = Dictionary(grouping: snapshot.counters, by: { $0.key.name })
        for name in counters.keys.sorted() {
            let points = counters[name, default: []].sorted { order($0.key, $1.key) }.map { series, value -> [String: Any] in
                ["attributes": attributes(series.attributes), "startTimeUnixNano": start, "timeUnixNano": time,
                 "asInt": String(value)]
            }
            metrics.append(metric(name, ["sum": ["aggregationTemporality": cumulative, "isMonotonic": true,
                                                  "dataPoints": points]]))
        }
        let histograms = Dictionary(grouping: snapshot.histograms, by: { $0.key.name })
        for name in histograms.keys.sorted() {
            let points = histograms[name, default: []].sorted { order($0.key, $1.key) }.map { series, value -> [String: Any] in
                ["attributes": attributes(series.attributes), "startTimeUnixNano": start, "timeUnixNano": time,
                 "count": String(value.count), "sum": value.sum,
                 "bucketCounts": value.bucketCounts.map(String.init), "explicitBounds": value.bounds]
            }
            metrics.append(metric(name, ["histogram": ["aggregationTemporality": cumulative, "dataPoints": points]]))
        }
        metrics.append(metric(TelemetryMetric.appUp, ["gauge": ["dataPoints": [["timeUnixNano": time, "asInt": "1"]]]]))

        let resource: [String: Any] = ["attributes": attributes([
            .init(key: "service.name",        value: "braus"),
            .init(key: "service.version",     value: configuration.appVersion),
            .init(key: "service.instance.id", value: configuration.installationID),
            .init(key: "os.type",             value: "darwin"),
            .init(key: "os.version",          value: configuration.osVersion),
            .init(key: "host.arch",           value: configuration.architecture),
        ])]
        let body: [String: Any] = ["resourceMetrics": [[
            "resource": resource,
            "scopeMetrics": [["scope": ["name": "braus", "version": configuration.appVersion], "metrics": metrics]],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    private static func metric(_ name: String, _ data: [String: Any]) -> [String: Any] {
        var metric = data
        metric["name"] = name
        if let unit = units[name] { metric["unit"] = unit }
        return metric
    }

    private static func attributes(_ attributes: [TelemetryRecorder.Attribute]) -> [[String: Any]] {
        attributes.map { ["key": $0.key, "value": ["stringValue": $0.value]] }
    }

    private static func order(_ a: TelemetryRecorder.Series, _ b: TelemetryRecorder.Series) -> Bool {
        a.attributes.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            < b.attributes.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    static func nanoseconds(_ date: Date) -> String {
        String(UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000))
    }
}
