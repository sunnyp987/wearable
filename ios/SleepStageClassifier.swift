//
//  SleepStageClassifier.swift
//  Drop into the OpenWhoop iOS project alongside WhoopScoreEngine.swift.
//
//  Approximates Whoop's sleep staging (Awake / Light / Deep / REM) using
//  30-second epochs of accelerometer motion + heart rate, the same class
//  of signals consumer actigraphy-based sleep trackers have used for years
//  (loosely descended from the Cole-Kripke approach), refined with HR/HRV
//  cues since we don't have the raw PPG waveform Whoop's own model uses.
//
//  CAVEATS:
//  - This will NOT match Whoop's stage-by-stage output exactly. Actigraphy+HR
//    heuristics are historically decent at Awake-vs-Asleep (~85-90% agreement
//    with polysomnography in validation studies) but much weaker at telling
//    Light/Deep/REM apart. Treat stage percentages as rough estimates, and
//    total sleep time / sleep efficiency as the more trustworthy numbers.
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
    /// Feed this from CoreMotion's accelerometer data, aggregated per epoch.
    let activityCount: Double
}

struct StagedEpoch {
    let start: Date
    let stage: SleepStage
}

struct SleepStageClassifier {

    static let epochSeconds: TimeInterval = 30

    /// Classify a full night. `motionEpochs` and `hrEpochs` must be pre-aligned
    /// to the same 30-second grid (same start times, same count).
    static func classify(
        motionEpochs: [MotionEpoch],
        hrEpochs: [HRSample],           // one representative/mean bpm per epoch
        hrvEpochs: [Double?]            // per-epoch RMSSD if available, else nil
    ) -> [StagedEpoch] {

        guard motionEpochs.count == hrEpochs.count else {
            assertionFailure("Motion and HR epochs must be aligned 1:1")
            return []
        }

        // Step 1: rough activity threshold from the night's own distribution,
        // since absolute accelerometer units vary by device/mounting.
        let sortedActivity = motionEpochs.map { $0.activityCount }.sorted()
        let median = sortedActivity[sortedActivity.count / 2]
        let awakeThreshold = max(median * 3.0, 1.0)

        // Step 2: resting HR proxy for the night = 10th percentile of HR epochs
        let sortedHR = hrEpochs.map { $0.bpm }.sorted()
        let nightRestingHR = sortedHR[max(0, Int(Double(sortedHR.count) * 0.10) - 1)]

        var rawStages: [SleepStage] = []

        for i in 0..<motionEpochs.count {
            let motion = motionEpochs[i].activityCount
            let hr = hrEpochs[i].bpm
            let hrv = hrvEpochs[i]

            if motion > awakeThreshold {
                rawStages.append(.awake)
                continue
            }

            let hrAboveResting = hr - nightRestingHR

            // Deep sleep: quiet body, HR at or near its lowest of the night,
            // and (if available) relatively high, stable HRV — parasympathetic
            // dominance is the physiological signature of deep/SWS.
            if hrAboveResting < 2, let hrv = hrv, hrv > 40 {
                rawStages.append(.deep)
                continue
            }

            // REM: body near-paralyzed (very low motion, often lower than deep)
            // but heart rate and HRV become irregular/elevated relative to
            // the surrounding deep-sleep baseline.
            if motion < median * 0.5 && hrAboveResting > 3 {
                rawStages.append(.rem)
                continue
            }

            rawStages.append(.light)
        }

        // Step 3: smooth with hysteresis — real sleep architecture doesn't
        // flip stage every 30 seconds. Collapse isolated single-epoch blips
        // into their neighboring stage.
        let smoothed = smooth(rawStages, minRunLength: 3)

        return zip(motionEpochs, smoothed).map { StagedEpoch(start: $0.start, stage: $1) }
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
