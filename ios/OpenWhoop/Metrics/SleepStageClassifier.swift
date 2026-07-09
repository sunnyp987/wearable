//
//  SleepStageClassifier.swift
//  Drop into the OpenWhoop iOS project alongside WhoopScoreEngine.swift.
//
//  Approximates Whoop's sleep staging (Awake / Light / Deep / REM) using
//  30-second epochs of accelerometer motion + heart rate, the same class
//  of signals consumer actigraphy-based sleep trackers have used for years
//  (loosely descended from the Cole-Kripke approach).
//
//  FIXED: the original version required motion and HR epochs to already be
//  pre-aligned 1:1 on the same 30s grid (same count, same start times). But
//  the two signals are logged at different rates and moments, so their raw
//  counts never actually matched in practice — the alignment guard tripped
//  on every real run and silently returned an EMPTY result (0m sleep,
//  recovery=0, no matter how much real data existed). This version takes
//  each signal with its own real timestamps plus the sleep window bounds,
//  and buckets both onto a shared 30s epoch grid internally — no external
//  pre-alignment required, and gaps in either signal are gap-filled from
//  their nearest neighboring bin rather than becoming a hard failure.
//
//  CAVEATS:
//  - This will NOT match Whoop's stage-by-stage output exactly. Actigraphy+HR
//    heuristics are historically decent at Awake-vs-Asleep (~85-90% agreement
//    with polysomnography in validation studies) but much weaker at telling
//    Light/Deep/REM apart. Treat stage percentages as rough estimates, and
//    total sleep time / sleep efficiency as the more trustworthy numbers.
//  - There is no real per-epoch HRV signal wired in yet (a prior version had
//    an hrvEpochs parameter that was always fed an array of nils from the
//    orchestrator, making its "deep sleep" branch permanently dead code).
//    Deep sleep here uses a simpler HR-only proxy instead; a genuine
//    per-epoch HRV signal would meaningfully improve deep/light separation
//    as a future enhancement.
//  - Not a medical device, not for diagnosing sleep disorders.
//

import Foundation

enum SleepStage: String {
    case awake
    case light
    case deep
    case rem
}

struct MotionEpoch {
    let start: Date
    /// Sum of accelerometer magnitude deltas within this epoch (activity counts).
    let activityCount: Double
}

struct StagedEpoch {
    let start: Date
    let stage: SleepStage
}

struct SleepStageClassifier {

    static let epochSeconds: TimeInterval = 30

    /// Classify a full night from independently-sampled motion and HR signals,
    /// bucketed onto a shared 30s grid spanning [windowStart, windowEnd].
    static func classify(
        windowStart: Date,
        windowEnd: Date,
        motionEpochs: [MotionEpoch],
        hrEpochs: [ScoringHRSample]
    ) -> [StagedEpoch] {
        guard windowEnd > windowStart else { return [] }
        let epochCount = max(1, Int(windowEnd.timeIntervalSince(windowStart) / epochSeconds))

        var motionBins = [[Double]](repeating: [], count: epochCount)
        for m in motionEpochs {
            guard let idx = binIndex(for: m.start, windowStart: windowStart, epochCount: epochCount) else { continue }
            motionBins[idx].append(m.activityCount)
        }
        var hrBins = [[Double]](repeating: [], count: epochCount)
        for h in hrEpochs {
            guard let idx = binIndex(for: h.timestamp, windowStart: windowStart, epochCount: epochCount) else { continue }
            hrBins[idx].append(h.bpm)
        }

        // Reduce each bin to a representative value: MEAN for both signals.
        // (Motion previously used sum-per-bin, which is oversensitive when
        // historical records are logged sparsely — a single incidental motion
        // reading in an otherwise-empty 30s bin could look like "awake" activity
        // even during genuine stillness, misclassifying whole nights as awake.
        // Mean keeps the value comparable regardless of how many raw samples
        // happened to land in a given bin.)
        let motionValues = fillGaps(motionBins.map { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) })
        let hrValues = fillGaps(hrBins.map { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) })

        guard !motionValues.isEmpty, motionValues.count == hrValues.count else { return [] }

        // Step 1: rough activity threshold from the night's own distribution,
        // since absolute accelerometer units vary by device/mounting.
        let sortedActivity = motionValues.sorted()
        let median = sortedActivity[sortedActivity.count / 2]
        let awakeThreshold = max(median * 3.0, 1.0)

        // Step 2: resting HR proxy for the night = 10th percentile of HR epochs.
        let sortedHR = hrValues.sorted()
        let nightRestingHR = sortedHR[max(0, Int(Double(sortedHR.count) * 0.10) - 1)]

        var rawStages: [SleepStage] = []
        for i in 0..<motionValues.count {
            let motion = motionValues[i]
            let hr = hrValues[i]
            let hrAboveResting = hr - nightRestingHR

            if motion > awakeThreshold {
                rawStages.append(.awake)
                continue
            }

            // REM: body near-paralyzed (very low motion) but HR elevated/
            // irregular relative to the night's baseline.
            if motion < median * 0.5 && hrAboveResting > 3 {
                rawStages.append(.rem)
                continue
            }

            // Deep sleep proxy (no per-epoch HRV available yet): quiet body
            // AND HR at or below the night's resting baseline.
            if hrAboveResting < 0 {
                rawStages.append(.deep)
                continue
            }

            rawStages.append(.light)
        }

        // Step 3: smooth with hysteresis — real sleep architecture doesn't
        // flip stage every 30 seconds. Collapse isolated single-epoch blips
        // into their neighboring stage.
        let smoothed = smooth(rawStages, minRunLength: 3)

        return (0..<smoothed.count).map { i in
            StagedEpoch(start: windowStart.addingTimeInterval(Double(i) * epochSeconds), stage: smoothed[i])
        }
    }

    private static func binIndex(for date: Date, windowStart: Date, epochCount: Int) -> Int? {
        let offset = date.timeIntervalSince(windowStart)
        guard offset >= 0 else { return nil }
        let idx = Int(offset / epochSeconds)
        return idx < epochCount ? idx : nil
    }

    /// Forward-fill then back-fill nil (empty) bins from their nearest non-nil
    /// neighbor, so a gap in one signal's sampling doesn't create a hole in
    /// the aligned output. Bins with no neighbor at all (e.g. totally empty
    /// input) fall back to 0.
    private static func fillGaps(_ values: [Double?]) -> [Double] {
        guard !values.isEmpty else { return [] }
        var result = values
        var last: Double? = nil
        for i in 0..<result.count {
            if let v = result[i] { last = v } else if let last { result[i] = last }
        }
        var next: Double? = nil
        for i in stride(from: result.count - 1, through: 0, by: -1) {
            if let v = result[i] { next = v } else if let next { result[i] = next }
        }
        return result.map { $0 ?? 0 }
    }

    /// Replace runs shorter than `minRunLength` with the stage of the run
    /// before them (simple hysteresis smoothing).
    private static func smooth(_ stages: [SleepStage], minRunLength: Int) -> [SleepStage] {
        guard !stages.isEmpty else { return [] }
        var result = stages

        var i = 0
        while i < result.count {
            var j = i
            while j < result.count && result[j] == result[i] { j += 1 }
            let runLength = j - i
            if runLength < minRunLength && i > 0 {
                let replacement = result[i - 1]
                for k in i..<j { result[k] = replacement }
            }
            i = j
        }
        return result
    }

    // MARK: - Summary stats from a staged night

    static func summarize(_ staged: [StagedEpoch]) -> (
        totalSleepHours: Double,
        efficiency: Double,
        lightHours: Double,
        deepHours: Double,
        remHours: Double,
        awakeHours: Double
    ) {
        let epochHours = epochSeconds / 3600.0
        let counts = Dictionary(grouping: staged, by: { $0.stage }).mapValues { Double($0.count) * epochHours }

        let light = counts[.light] ?? 0
        let deep = counts[.deep] ?? 0
        let rem = counts[.rem] ?? 0
        let awake = counts[.awake] ?? 0
        let asleep = light + deep + rem
        let total = asleep + awake

        return (
            totalSleepHours: asleep,
            efficiency: total > 0 ? asleep / total : 0,
            lightHours: light,
            deepHours: deep,
            remHours: rem,
            awakeHours: awake
        )
    }
}
