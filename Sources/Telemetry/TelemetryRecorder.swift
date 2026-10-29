//
//  TelemetryRecorder.swift
//  Braus
//
//  Created by Ronaldo Zefi on 26/10/2026.
//

import Foundation
import Synchronization

/// TelemetryRecorder keeps the metrics of this process since it started recording: counters and histograms,
/// each series named by its metric and its attributes. The totals only grow, so a snapshot is cumulative and
/// a snapshot that never reaches the collector loses nothing the next one does not carry.
///
/// Recording is synchronous and cheap, under one lock, so a tool call pays no suspension for it. A recorder that
/// is not recording drops every value, which is what a test, a check run or a turned-off installation sees.
public final class TelemetryRecorder: Sendable {

    /// One series: a metric's name and its attributes, sorted by key.
    public struct Series: Sendable, Hashable {
        public let name      : String
        public let attributes: [Attribute]

        public init(_ name: String, _ attributes: [String: String]) {
            self.name       = name
            self.attributes = attributes.sorted { $0.key < $1.key }.map { Attribute(key: $0.key, value: $0.value) }
        }
    }

    public struct Attribute: Sendable, Hashable {
        public let key  : String
        public let value: String
    }

    /// A histogram's state: how many values fell at or under each bound, and above the last, their count and sum.
    public struct Histogram: Sendable, Equatable {
        public let bounds      : [Double]
        public var bucketCounts: [Int]
        public var count       : Int    = 0
        public var sum         : Double = 0

        init(bounds: [Double]) {
            self.bounds       = bounds
            self.bucketCounts = Array(repeating: 0, count: bounds.count + 1)
        }

        mutating func add(_ value: Double) {
            let index = bounds.firstIndex { value <= $0 } ?? bounds.count
            bucketCounts[index] += 1
            count += 1
            sum   += value
        }
    }

    /// Everything recorded since `start`, at `time`.
    public struct Snapshot: Sendable, Equatable {
        public let start     : Date
        public let time      : Date
        public let counters  : [Series: Int]
        public let histograms: [Series: Histogram]
    }

    private struct State {
        var start     : Date?
        var counters  : [Series: Int]       = [:]
        var histograms: [Series: Histogram] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Starts recording at `time`; a recorder already recording keeps its totals.
    public func start(at time: Date = Date()) {
        state.withLock { if $0.start == nil { $0.start = time } }
    }

    /// Stops recording and forgets every total.
    public func stop() {
        state.withLock { $0 = State() }
    }

    public var isRecording: Bool { state.withLock { $0.start != nil } }

    /// Adds `amount` to a counter.
    public func add(_ amount: Int = 1, to series: Series) {
        state.withLock { state in
            guard state.start != nil else { return }
            state.counters[series, default: 0] += amount
        }
    }

    /// Records one value of a histogram whose buckets end at `bounds`. A series keeps the bounds of its first value.
    public func record(_ value: Double, in series: Series, bounds: [Double]) {
        state.withLock { state in
            guard state.start != nil, value.isFinite else { return }
            state.histograms[series, default: Histogram(bounds: bounds)].add(max(0, value))
        }
    }

    /// The totals at `time`, or nil when the recorder is not recording.
    public func snapshot(at time: Date = Date()) -> Snapshot? {
        state.withLock { state in
            guard let start = state.start else { return nil }
            return Snapshot(start: start, time: time, counters: state.counters, histograms: state.histograms)
        }
    }
}
