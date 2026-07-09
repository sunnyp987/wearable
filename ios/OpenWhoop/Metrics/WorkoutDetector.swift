//
//  WorkoutDetector.swift
//  Drop into ios/OpenWhoop/Metrics/ alongside the other scoring files.
//
//  Fully local, on-device workout auto-detection — no server required. Scans
//  a day's HR samples for sustained bouts of elevated heart rate and produces
//  `Workout` records matching the exact shape ServerSync.getWorkouts() would
//  have returned, so WorkoutsView/WorkoutDetailView need ZERO changes.
//
//  METHOD: a bout is a contiguous run where HR stays at or above a %-of-heart-
//  -rate-reserve threshold for at least a minimum duration, tolerating brief
//  dips (e.g. a red light, a pause) without ending the bout. This mirrors the
//  spirit of Whoop's own auto-detected-activity approach, at a much simpler
//  level — it will not distinguish activity TYPE (run vs bike vs walk), only
//  "there was a sustained elevated-effort period here."
//
//  KNOWN LIMITATIONS (be upfront about these, don't overclaim):
//  - No activity-type classification — `kind` is always "Activity".
//  - No calorie estimate — that needs body profile (weight/age/sex) wiring
//    this file doesn't have access to; caloriesKcal/Kj are always nil.
//  - hrmax is an ESTIMATE (passed in, e.g. 220-age), not a measured max —
//    hrmaxSource reflects that honestly.
//  - Zone boundaries use a standard 5-zone %HRR scheme (widely used, but not
//    necessarily identical to WHOOP's own proprietary zone definitions).
//

import Foundation
import WhoopProtocol

struct WorkoutDetector {

    /// Minimum sustained duration for a bout to count as a workout (seconds).
    /// 8 minutes filters out brief errands/stair climbs while still catching
    /// short but real training sessions.
    static let minBoutSeconds: TimeInterval = 8 * 60

    /// Minimum %HRR to count as "elevated effort" — roughly Zone 2+.
    static let elevatedHRRThreshold: Double = 0.40

    /// How long a dip below threshold is tolerated before ending a bout
    /// (brief pauses, red lights, rest between sets).
    static let toleranceGapSeconds: TimeInterval = 90

    /// Detect workouts from a day's (or any range's) HR samples.
    static func detect(
        hrSamples: [ScoringHRSample],
        deviceId: String,
        restingHR: Double,
        maxHR: Double
    ) -> [Workout] {
        guard maxHR > restingHR else { return [] }
        let sorted = hrSamples.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return [] }

        func hrrFraction(_ bpm: Double) -> Double {
            max(0, min(1, (bpm - restingHR) / (maxHR - restingHR)))
        }

        var workouts: [Workout] = []
        var boutSamples: [ScoringHRSample] = []
        var lastElevatedAt: Date? = nil

        func closeBoutIfValid() {
            defer { boutSamples = []; lastElevatedAt = nil }
            guard let first = boutSamples.first?.timestamp,
                  let last = boutSamples.last?.timestamp,
                  last.timeIntervalSince(first) >= minBoutSeconds else { return }

            let bpmValues = boutSamples.map { $0.bpm }
            let avgHr = bpmValues.reduce(0, +) / Double(bpmValues.count)
            let peakHr = Int(bpmValues.max() ?? avgHr)
            let durationS = Int(last.timeIntervalSince(first))

            let avgHrrPct = hrrFraction(avgHr) * 100

            // 5-zone %HRR scheme (standard, not necessarily WHOOP's exact proprietary
            // boundaries): Z1 <50%, Z2 50-60%, Z3 60-70%, Z4 70-80%, Z5 80%+.
            var zoneSeconds: [Int: Double] = [0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
            for i in 1..<boutSamples.count {
                let dt = boutSamples[i].timestamp.timeIntervalSince(boutSamples[i - 1].timestamp)
                let frac = hrrFraction(boutSamples[i].bpm)
                let zone: Int
                switch frac {
                case ..<0.40: zone = 1
                case 0.40..<0.50: zone = 2
                case 0.50..<0.60: zone = 3
                case 0.60..<0.70: zone = 4
                default: zone = 5
                }
                zoneSeconds[zone, default: 0] += dt
            }
            let totalZoneSeconds = zoneSeconds.values.reduce(0, +)
            let zoneTimePct: [Int: Double] = totalZoneSeconds > 0
                ? zoneSeconds.mapValues { ($0 / totalZoneSeconds) * 100 }
                : [:]

            let startTs = Int(first.timeIntervalSince1970)
            workouts.append(Workout(
                id: "\(deviceId)|\(startTs)",
                deviceId: deviceId,
                startTs: startTs,
                endTs: Int(last.timeIntervalSince1970),
                avgHr: avgHr,
                peakHr: peakHr,
                strain: StrainScorer.dailyStrain(hrSamples: boutSamples, restingHR: restingHR, maxHR: maxHR),
                kind: "Activity",   // no activity-type classification available locally
                durationS: durationS,
                zoneTimePct: zoneTimePct,
                avgHrrPct: avgHrrPct,
                hrmax: maxHR,
                hrmaxSource: "estimated",  // not a measured max — see file header
                caloriesKcal: nil,          // needs body profile wiring; not available here
                caloriesKj: nil
            ))
        }

        for sample in sorted {
            let elevated = hrrFraction(sample.bpm) >= elevatedHRRThreshold
            if elevated {
                boutSamples.append(sample)
                lastElevatedAt = sample.timestamp
            } else if let lastElevated = lastElevatedAt {
                if sample.timestamp.timeIntervalSince(lastElevated) > toleranceGapSeconds {
                    closeBoutIfValid()
                } else {
                    // Within tolerance — keep the bout open, include this
                    // lower sample so duration/avg reflect the brief dip.
                    boutSamples.append(sample)
                }
            }
        }
        closeBoutIfValid()  // flush any bout still open at the end of the range

        return workouts
    }
}
