//
//  WhoopDataAdapter.swift
//  Drop into ios/ alongside the other files.
//
//  REVISED: earlier version of this file parsed raw ParsedFrame records
//  directly. That's unnecessary — WhoopStore's Reads.swift already queries
//  flattened, typed, per-signal tables (hrSample, rrInterval, gravitySample,
//  event) by time range. This adapter now just converts those WhoopProtocol
//  types (ts: Int unix-seconds) into the scoring engine's own Scoring* types
//  (timestamp: Date), nothing more.
//

import Foundation
import WhoopProtocol

struct WhoopDataAdapter {

    static func scoringHRSamples(from samples: [HRSample]) -> [ScoringHRSample] {
        samples.map { ScoringHRSample(timestamp: Date(timeIntervalSince1970: Double($0.ts)), bpm: Double($0.bpm)) }
    }

    /// Pool RR intervals (already flattened, one row per beat) into plain
    /// millisecond values for BaselineEngine.rmssd. Chronological order matters.
    static func rrIntervalsMs(from intervals: [RRInterval]) -> [Double] {
        intervals.sorted { $0.ts < $1.ts }.map { Double($0.rrMs) }
    }

    /// Motion epochs derived from consecutive gravity-vector deltas.
    /// GravitySample is already one row per reading — no frame parsing needed.
    static func motionEpochs(from samples: [GravitySample]) -> [MotionEpoch] {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard sorted.count > 1 else { return [] }

        var epochs: [MotionEpoch] = []
        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]
            let delta = sqrt(pow(curr.x - prev.x, 2) + pow(curr.y - prev.y, 2) + pow(curr.z - prev.z, 2))
            epochs.append(MotionEpoch(start: Date(timeIntervalSince1970: Double(curr.ts)), activityCount: delta))
        }
        return epochs
    }

    /// Worn (WRIST_ON -> WRIST_OFF) intervals from the flattened event table.
    /// WhoopEvent.kind is already a plain string like "WRIST_ON" / "WRIST_OFF"
    /// (decoded from the EventNumber enum at ingest time).
    static func wornIntervals(from events: [WhoopEvent]) -> [(start: Date, end: Date)] {
        let sorted = events.sorted { $0.ts < $1.ts }
        var intervals: [(start: Date, end: Date)] = []
        var wristOnAt: Date? = nil
        for event in sorted {
            let t = Date(timeIntervalSince1970: Double(event.ts))
            if event.kind == "WRIST_ON" { wristOnAt = t }
            if event.kind == "WRIST_OFF", let start = wristOnAt {
                intervals.append((start: start, end: t))
                wristOnAt = nil
            }
        }
        return intervals
    }
}
