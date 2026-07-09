//
//  WorkoutDetector.swift
//  On-device workout auto-detection from the raw HR stream.
//
//  BACKGROUND: WorkoutsView / MetricsRepository.workouts() originally only read from
//  ServerSync.getWorkouts(), i.e. GET /v1/workouts on the optional self-hosted server. With
//  no server configured (the common case for a purely local install — README frames the
//  server as optional), MetricsRepository.workouts() always returned [], so the Workouts tab
//  was permanently empty regardless of how much real activity data was on the phone. Sleep and
//  Strain already have on-device computation (WhoopScoringOrchestrator); this gives Workouts
//  the same local-first treatment, mirroring WHOOP's own auto-detection: a workout is a
//  sustained period of elevated heart-rate-reserve.
//
//  METHOD: Karvonen %HRR (heart-rate reserve) zones, same basis StrainScorer already uses.
//  A bout is a maximal run of samples at zone >= 2 (>=60% HRR), bridging gaps up to
//  `mergeGapSeconds` so interval efforts (e.g. run/walk intervals) aren't split into many
//  tiny bouts, and requiring at least `minActiveMinutes` of total span to filter out brief
//  HR spikes (stairs, a single flight, etc.) that aren't real workouts.
//
//  CAVEATS: no calorie model is calibrated against ground truth here, so caloriesKcal/Kj are
//  always nil (same "—" treatment the UI already gives null calories from the server path).
//  `kind` (activity type) is always nil — WHOOP's activity classifier isn't reproduced.
//

import Foundation

struct WorkoutDetector {

    static let minActiveMinutes: Double = 6
    static let mergeGapSeconds: TimeInterval = 4 * 60

    /// Karvonen %HRR zone boundaries for zones 0...5 (upper-bound exclusive), matching the
    /// zone labels WorkoutDetailView already renders (Rest/Very Light/Light/Moderate/Hard/Max).
    private static let zoneBoundaries: [Double] = [0.0, 0.50, 0.60, 0.70, 0.80, 0.90, 1.01]

    private static func zone(forHRRFraction f: Double) -> Int {
        for i in 0..<(zoneBoundaries.count - 1) {
            if f >= zoneBoundaries[i] && f < zoneBoundaries[i + 1] { return i }
        }
        return f >= zoneBoundaries[zoneBoundaries.count - 1] ? 5 : 0
    }

    /// Detect workout bouts from a (not-necessarily-sorted) HR sample series over some range.
    static func detect(
        hrSamples: [ScoringHRSample],
        restingHR: Double,
        maxHR: Double,
        deviceId: String,
        hrmaxSource: String
    ) -> [Workout] {
        let reserve = max(maxHR - restingHR, 1)
        let sorted = hrSamples.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count > 1 else { return [] }

        struct Point { let ts: Date; let bpm: Double; let frac: Double }
        let points = sorted.map { s in
            Point(ts: s.timestamp, bpm: s.bpm, frac: (s.bpm - restingHR) / reserve)
        }

        // Group into candidate bouts: consecutive elevated (zone >= 2) samples, bridging
        // short non-elevated gaps so a brief rest interval doesn't split one workout in two.
        var bouts: [[Point]] = []
        var current: [Point] = []
        var lastElevatedTs: Date? = nil

        for p in points {
            let elevated = p.frac >= zoneBoundaries[2]
            if elevated {
                if let last = lastElevatedTs, p.ts.timeIntervalSince(last) > mergeGapSeconds, !current.isEmpty {
                    bouts.append(current)
                    current = []
                }
                current.append(p)
                lastElevatedTs = p.ts
            } else if !current.isEmpty, let last = lastElevatedTs, p.ts.timeIntervalSince(last) <= mergeGapSeconds {
                current.append(p)   // bridge: keep the bout open through a short rest interval
            } else if !current.isEmpty {
                bouts.append(current)
                current = []
            }
        }
        if !current.isEmpty { bouts.append(current) }

        return bouts.compactMap { bout -> Workout? in
            guard let start = bout.first?.ts, let end = bout.last?.ts else { return nil }
            let durationS = Int(end.timeIntervalSince(start))
            guard Double(durationS) / 60.0 >= minActiveMinutes else { return nil }

            let bpms = bout.map { $0.bpm }
            let avgHr = bpms.reduce(0, +) / Double(bpms.count)
            let peakHr = Int(bpms.max() ?? avgHr)
            let avgFrac = bout.map { $0.frac }.reduce(0, +) / Double(bout.count)

            // Zone time %, weighted by the gap to the next sample (not just a per-sample count)
            // so sparsely/densely logged stretches don't skew the split.
            var zoneSeconds = [Int: Double]()
            for i in 0..<bout.count {
                let dt: Double
                if i + 1 < bout.count { dt = max(0, bout[i + 1].ts.timeIntervalSince(bout[i].ts)) }
                else { dt = i > 0 ? max(0, bout[i].ts.timeIntervalSince(bout[i - 1].ts)) : 1 }
                zoneSeconds[zone(forHRRFraction: bout[i].frac), default: 0] += dt
            }
            let totalZoneSeconds = zoneSeconds.values.reduce(0, +)
            var zonePct: [Int: Double] = [:]
            if totalZoneSeconds > 0 {
                for (z, secs) in zoneSeconds { zonePct[z] = secs / totalZoneSeconds * 100 }
            }

            let boutSamples = bout.map { ScoringHRSample(timestamp: $0.ts, bpm: $0.bpm) }
            let strain = StrainScorer.dailyStrain(hrSamples: boutSamples, restingHR: restingHR, maxHR: maxHR)

            return Workout(
                id: "\(deviceId)|\(Int(start.timeIntervalSince1970))",
                deviceId: deviceId,
                startTs: Int(start.timeIntervalSince1970),
                endTs: Int(end.timeIntervalSince1970),
                avgHr: avgHr,
                peakHr: peakHr,
                strain: strain,
                kind: nil,
                durationS: durationS,
                zoneTimePct: zonePct,
                avgHrrPct: avgFrac * 100,
                hrmax: maxHR,
                hrmaxSource: hrmaxSource,
                caloriesKcal: nil,
                caloriesKj: nil
            )
        }
    }
}
