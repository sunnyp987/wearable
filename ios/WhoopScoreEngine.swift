//
//  WhoopScoreEngine.swift
//  Drop into the OpenWhoop iOS project (johnmiddleton12/wearable).
//
//  Consumes decoded sensor records already produced by that project's
//  BLE pipeline (RR-intervals / HRV, HR samples, resting HR, sleep windows)
//  and produces the three scores a Whoop subscription normally computes
//  server-side: Recovery, Strain, and rolling HRV/RHR baselines.
//
//  IMPORTANT CAVEATS (read before trusting this for training decisions):
//  - This is a best-effort statistical approximation of Whoop's public
//    methodology (RMSSD-based HRV, log-scaled cumulative strain, baseline
//    deviation recovery). It is NOT Whoop's actual proprietary algorithm,
//    which uses additional signals (skin temp, SpO2, blood alcohol proxy,
//    respiratory rate trend, and a trained model) that aren't fully
//    reverse-engineered.
//  - Not a medical device. Don't use this to make health decisions.
//  - Absolute recovery percentages will not exactly match what Whoop showed
//    you historically — that's expected. Trends over time are the useful
//    signal, not the exact number.
//

import Foundation

// MARK: - Input types (map these from OpenWhoop's decoded records)

// NOTE: prefixed "Scoring" because WhoopProtocol (via WhoopStore's Reads.swift)
// already declares its own HRSample/RRInterval/GravitySample/WhoopEvent types
// with a different shape (ts: Int unix-seconds instead of Date). These are
// the scoring engine's own internal types — WhoopDataAdapter converts between
// the two, so this file never needs to import WhoopProtocol at all.
struct ScoringHRSample {
    let timestamp: Date
    let bpm: Double
}

struct SleepSession {
    let start: Date
    let end: Date
    /// Fraction of session actually asleep (from motion+HR heuristic, 0...1)
    let sleepEfficiency: Double
    /// Hours of sleep the recovery-need model estimates you needed
    let sleepNeedHours: Double
    let actualSleepHours: Double
}

// MARK: - HRV / RHR baseline engine

/// Maintains a rolling baseline so today's HRV/RHR can be expressed as a
/// deviation, which is what actually drives the recovery score (not raw HRV).
final class BaselineEngine {

    private(set) var hrvHistory: [(date: Date, rmssd: Double)] = []
    private(set) var rhrHistory: [(date: Date, bpm: Double)] = []

    private let windowDays: Int

    init(windowDays: Int = 14) {
        self.windowDays = windowDays
    }

    /// Root Mean Square of Successive Differences — the standard HRV metric
    /// Whoop and most wearables use (captured overnight for stability).
    static func rmssd(fromRRIntervalsMs rr: [Double]) -> Double? {
        guard rr.count > 1 else { return nil }
        var sumSquaredDiffs = 0.0
        for i in 1..<rr.count {
            let diff = rr[i] - rr[i - 1]
            sumSquaredDiffs += diff * diff
        }
        let meanSquaredDiff = sumSquaredDiffs / Double(rr.count - 1)
        return sqrt(meanSquaredDiff)
    }

    /// Feed in last night's overnight HRV sample (most stable window, mirrors
    /// how Whoop captures HRV primarily during sleep rather than all day).
    func recordNightlyHRV(date: Date, rrIntervalsMs: [Double]) {
        guard let rmssd = Self.rmssd(fromRRIntervalsMs: rrIntervalsMs) else { return }
        hrvHistory.append((date, rmssd))
        prune(&hrvHistory)
    }

    func recordRestingHR(date: Date, overnightHRSamples: [ScoringHRSample]) {
        guard !overnightHRSamples.isEmpty else { return }
        // RHR = lowest sustained HR overnight; approximate with 10th percentile
        // rather than absolute min, to avoid single-sample sensor noise.
        let sorted = overnightHRSamples.map { $0.bpm }.sorted()
        let idx = max(0, Int(Double(sorted.count) * 0.10) - 1)
        rhrHistory.append((date, sorted[idx]))
        prune(&rhrHistory)
    }

    private func prune(_ history: inout [(date: Date, rmssd: Double)]) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date())!
        history.removeAll { $0.date < cutoff }
    }
    private func prune(_ history: inout [(date: Date, bpm: Double)]) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date())!
        history.removeAll { $0.date < cutoff }
    }

    var hrvBaseline: Double? {
        guard !hrvHistory.isEmpty else { return nil }
        return hrvHistory.map { $0.rmssd }.reduce(0, +) / Double(hrvHistory.count)
    }

    var hrvStdDev: Double? {
        guard let mean = hrvBaseline, hrvHistory.count > 1 else { return nil }
        let variance = hrvHistory.map { pow($0.rmssd - mean, 2) }.reduce(0, +) / Double(hrvHistory.count - 1)
        return sqrt(variance)
    }

    var rhrBaseline: Double? {
        guard !rhrHistory.isEmpty else { return nil }
        return rhrHistory.map { $0.bpm }.reduce(0, +) / Double(rhrHistory.count)
    }
}

// MARK: - Recovery score

enum RecoveryBand: String {
    case green   // 67-100%: primed to perform
    case yellow  // 34-66%: maintaining
    case red     // 0-33%: compromised, prioritize rest
}

struct RecoveryResult {
    let percentage: Double        // 0...100
    let band: RecoveryBand
    let hrvDeviationSD: Double?   // how many std devs today's HRV is from baseline
    let rhrDeviationBpm: Double?
}

struct RecoveryScorer {

    /// Composite recovery score. Weights approximate Whoop's published emphasis:
    /// HRV deviation carries the most weight, RHR deviation second, sleep
    /// performance third. All inputs are expressed as z-scores or fractions
    /// so the composite is scale-free.
    static func score(
        todayHRVRmssd: Double?,
        baseline: BaselineEngine,
        lastNightSleep: SleepSession?
    ) -> RecoveryResult {

        var components: [(value: Double, weight: Double)] = []
        var hrvDevSD: Double? = nil
        var rhrDevBpm: Double? = nil

        // --- HRV component (weight 0.5) ---
        if let today = todayHRVRmssd,
           let mean = baseline.hrvBaseline,
           let sd = baseline.hrvStdDev, sd > 0 {
            let z = (today - mean) / sd
            hrvDevSD = z
            // Map z-score to 0...1: z=0 -> 0.5, z=+2 -> ~1.0, z=-2 -> ~0.0
            let mapped = clamp(0.5 + z / 4.0, 0, 1)
            components.append((mapped, 0.5))
        }

        // --- RHR component (weight 0.3) — lower RHR than baseline = better ---
        if let today = lastNightSleep != nil ? todayRestingHR(from: lastNightSleep!) : nil,
           let mean = baseline.rhrBaseline {
            let dev = today - mean
            rhrDevBpm = dev
            // -5 bpm (better) -> ~1.0, 0 -> 0.5, +5 bpm (worse) -> ~0.0
            let mapped = clamp(0.5 - dev / 10.0, 0, 1)
            components.append((mapped, 0.3))
        }

        // --- Sleep performance component (weight 0.2) ---
        if let sleep = lastNightSleep {
            let performance = clamp(sleep.actualSleepHours / max(sleep.sleepNeedHours, 0.1), 0, 1)
            components.append((performance, 0.2))
        }

        guard !components.isEmpty else {
            return RecoveryResult(percentage: 50, band: .yellow, hrvDeviationSD: nil, rhrDeviationBpm: nil)
        }

        let totalWeight = components.reduce(0) { $0 + $1.weight }
        let weightedSum = components.reduce(0) { $0 + $1.value * $1.weight }
        let pct = clamp(weightedSum / totalWeight, 0, 1) * 100

        let band: RecoveryBand = pct >= 67 ? .green : (pct >= 34 ? .yellow : .red)

        return RecoveryResult(percentage: pct, band: band, hrvDeviationSD: hrvDevSD, rhrDeviationBpm: rhrDevBpm)
    }

    private static func todayRestingHR(from sleep: SleepSession) -> Double? {
        // Placeholder hook — wire this to the overnight HR percentile calc
        // (same logic as BaselineEngine.recordRestingHR) for the most recent night.
        return nil
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}

// MARK: - Strain score

/// Whoop's Strain is a 0-21 logarithmically-scaled cumulative cardiovascular
/// load score, similar in spirit to a modified TRIMP (Training Impulse).
/// It accumulates through the day and never decreases.
struct StrainScorer {

    /// Per-sample contribution based on % of heart rate reserve (Karvonen method).
    /// restingHR and maxHR should come from the user's baseline / age-estimated max.
    static func instantaneousLoad(bpm: Double, restingHR: Double, maxHR: Double) -> Double {
        let hrReserveFraction = clamp((bpm - restingHR) / max(maxHR - restingHR, 1), 0, 1)
        // Exponential weighting so high-intensity effort counts disproportionately,
        // mirroring how strain accelerates during hard efforts vs. daily activity.
        return pow(hrReserveFraction, 2.0)
    }

    /// Accumulate instantaneous loads across a day's HR samples into a 0-21 score.
    static func dailyStrain(hrSamples: [ScoringHRSample], restingHR: Double, maxHR: Double, sampleIntervalSeconds: Double = 1.0) -> Double {
        guard !hrSamples.isEmpty else { return 0 }
        var cumulativeLoad = 0.0
        for sample in hrSamples {
            cumulativeLoad += instantaneousLoad(bpm: sample.bpm, restingHR: restingHR, maxHR: maxHR) * sampleIntervalSeconds
        }
        // Log-scale the raw cumulative load onto 0...21, calibrated so a full
        // hard training day lands roughly in the high teens. The constant here
        // is a tuning knob — adjust against your own historical Whoop strain
        // values from your CSV export to calibrate it to your own physiology.
        let scaled = log(1 + cumulativeLoad) * 2.1
        return clamp(scaled, 0, 21)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}
