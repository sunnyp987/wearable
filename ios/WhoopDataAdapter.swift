//
//  WhoopDataAdapter.swift
//  Drop into ios/ (or a shared package) alongside WhoopScoreEngine.swift and
//  SleepStageClassifier.swift.
//
//  Converts decoded ParsedFrame records (from Interpreter.swift /
//  parseFrame(_:)) into the input types WhoopScoreEngine and
//  SleepStageClassifier expect. This is the seam between the raw protocol
//  layer and the scoring layer.
//
//  STATUS / OPEN ITEMS:
//  - HR + timestamp: solid, wired below.
//  - Motion: derived from gravity-vector deltas between consecutive
//    HISTORICAL_DATA(v24) records (there is no raw "activity count" field —
//    gravity_x/y/z is an orientation vector, so motion = how much it changes).
//  - HRV (RR intervals): NOT wired yet. rr_count tells us how many intervals
//    exist per record, but the actual millisecond values are populated by a
//    "post" hook (see protocol/whoop_protocol.json -> "post": "historical_data")
//    that lives in PostHooks.swift, which I haven't seen yet. Once you paste
//    that file, I'll fill in `extractRRIntervals(from:)` below with the real
//    key name instead of the placeholder.
//  - SpO2 / skin temp: schema explicitly notes these are raw ADC values that
//    WHOOP converts to real units in their cloud with an undisclosed formula.
//    We surface the raw values for relative-trend use (e.g. as a secondary
//    sleep-staging signal) but cannot present a calibrated %/°C number.
//

import Foundation

struct WhoopDataAdapter {

    /// HISTORICAL_DATA(v24) records, in chronological order, become HR samples.
    static func hrSamples(fromHistoricalFrames frames: [ParsedFrame]) -> [HRSample] {
        frames.compactMap { frame -> HRSample? in
            guard frame.typeName == "HISTORICAL_DATA",
                  let unix = frame.parsed["unix"]?.intValue,
                  let hr = frame.parsed["heart_rate"]?.intValue else { return nil }
            return HRSample(timestamp: Date(timeIntervalSince1970: Double(unix)), bpm: Double(hr))
        }
    }

    /// Motion epochs derived from consecutive gravity-vector deltas.
    /// Each HISTORICAL_DATA(v24) record has gravity_x/y/z (a unit-ish g vector).
    /// A quiet/still wrist has a near-constant vector; movement shows up as
    /// frame-to-frame change in that vector, which we use as our activityCount
    /// proxy for SleepStageClassifier.
    static func motionEpochs(fromHistoricalFrames frames: [ParsedFrame]) -> [MotionEpoch] {
        let sorted = frames
            .filter { $0.typeName == "HISTORICAL_DATA" }
            .compactMap { frame -> (Date, Double, Double, Double)? in
                guard let unix = frame.parsed["unix"]?.intValue,
                      let gx = frame.parsed["gravity_x"]?.doubleValue,
                      let gy = frame.parsed["gravity_y"]?.doubleValue,
                      let gz = frame.parsed["gravity_z"]?.doubleValue else { return nil }
                return (Date(timeIntervalSince1970: Double(unix)), gx, gy, gz)
            }
            .sorted { $0.0 < $1.0 }

        guard sorted.count > 1 else { return [] }

        var epochs: [MotionEpoch] = []
        for i in 1..<sorted.count {
            let (t0, x0, y0, z0) = sorted[i - 1]
            let (t1, x1, y1, z1) = sorted[i]
            let delta = sqrt(pow(x1 - x0, 2) + pow(y1 - y0, 2) + pow(z1 - z0, 2))
            epochs.append(MotionEpoch(start: t1, activityCount: delta))
            _ = t0 // silence unused warning; t0 kept for clarity of the pairing
        }
        return epochs
    }

    /// Confirmed via PostHooks.swift: RR intervals surface under "rr_intervals"
    /// as an intArray, in milliseconds. NOTE: capped at 4 values per
    /// HISTORICAL_DATA record (min(rrn, 4) in the decoder), so any single
    /// record's RR list is sparse — always pool across a full night's worth
    /// of records before computing RMSSD, never compute it per-record.
    static func extractRRIntervals(from frame: ParsedFrame) -> [Double]? {
        guard let arr = frame.parsed["rr_intervals"]?.intArrayValue, !arr.isEmpty else { return nil }
        return arr.map { Double($0) }
    }

    /// Build nightly HRV samples for BaselineEngine by pooling RR intervals
    /// from every HISTORICAL_DATA record in the overnight window — this is
    /// the correct granularity given the 4-per-record cap above.
    static func hrvSamples(fromHistoricalFrames frames: [ParsedFrame], night: (start: Date, end: Date)) -> [Double] {
        frames
            .filter { $0.typeName == "HISTORICAL_DATA" }
            .compactMap { frame -> (Date, [Double])? in
                guard let unix = frame.parsed["unix"]?.intValue else { return nil }
                let t = Date(timeIntervalSince1970: Double(unix))
                guard t >= night.start && t <= night.end else { return nil }
                guard let rr = extractRRIntervals(from: frame) else { return nil }
                return (t, rr)
            }
            .sorted { $0.0 < $1.0 }  // chronological pooling order matters for RMSSD
            .flatMap { $0.1 }
    }

    /// Wrist-on/off events (from EVENT frames) — useful for trimming HR/motion
    /// data to periods the strap was actually worn, avoiding false "sleep" reads
    /// from an off-wrist strap sitting on a nightstand.
    static func wornIntervals(fromEventFrames frames: [ParsedFrame]) -> [(start: Date, end: Date)] {
        let sorted = frames
            .filter { $0.typeName == "EVENT" }
            .compactMap { frame -> (String, Date)? in
                guard let eventName = frame.parsed["event"]?.stringValue,
                      let ts = frame.parsed["event_timestamp"]?.intValue else { return nil }
                return (eventName, Date(timeIntervalSince1970: Double(ts)))
            }
            .sorted { $0.1 < $1.1 }

        var intervals: [(start: Date, end: Date)] = []
        var wristOnAt: Date? = nil
        for (name, ts) in sorted {
            if name == "WRIST_ON" { wristOnAt = ts }
            if name == "WRIST_OFF", let start = wristOnAt {
                intervals.append((start: start, end: ts))
                wristOnAt = nil
            }
        }
        return intervals
    }
}
