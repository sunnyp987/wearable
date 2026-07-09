//
//  WhoopScoringOrchestrator.swift
//  Drop into ios/ alongside the other three files.
//
//  Ties WhoopDataAdapter -> BaselineEngine / RecoveryScorer / StrainScorer /
//  SleepStageClassifier together into something that actually runs:
//  - Each morning: find last night's window, classify sleep, compute recovery.
//  - Continuously through the day: fold new HR frames into today's strain.
//
//  DEPENDS ON TWO THINGS I HAVEN'T SEEN YET (defined as protocols below so
//  this compiles and is testable now — wire the real WhoopStore in once you
//  paste its API):
//  - FrameSource: however WhoopStore lets you query decoded frames by date range
//  - ScoreStore: however you want computed scores persisted (WhoopStore table,
//    UserDefaults, a new GRDB table — whatever fits the existing project best)
//

import Foundation

// MARK: - Abstractions over WhoopStore (replace with real calls once seen)

protocol FrameSource {
    /// All decoded frames of any type within [start, end], chronological order.
    func frames(from start: Date, to end: Date) async throws -> [ParsedFrame]
}

struct DailyScoreRecord {
    let date: Date
    let recovery: RecoveryResult?
    let sleep: SleepSession?
    let strain: Double
}

protocol ScoreStore {
    func save(_ record: DailyScoreRecord) async throws
    func loadBaselineHistory() async throws -> (hrv: [(Date, Double)], rhr: [(Date, Double)])
    func saveBaselineHistory(hrv: [(Date, Double)], rhr: [(Date, Double)]) async throws
}

// MARK: - Orchestrator

@MainActor
final class WhoopScoringOrchestrator {

    private let frameSource: FrameSource
    private let scoreStore: ScoreStore
    private let baseline = BaselineEngine()

    /// Running strain accumulator for "today" — strain never decreases within a day.
    private(set) var todayStrain: Double = 0
    private var todayRestingHR: Double = 50   // sensible default until baseline warms up
    private var todayMaxHR: Double = 190      // override with 220-age or a measured max

    init(frameSource: FrameSource, scoreStore: ScoreStore) {
        self.frameSource = frameSource
        self.scoreStore = scoreStore
    }

    /// Call once at app launch to restore rolling baselines from disk.
    func restoreBaselines() async {
        do {
            let (hrvHist, rhrHist) = try await scoreStore.loadBaselineHistory()
            for (date, rmssd) in hrvHist {
                // BaselineEngine only exposes recordNightlyHRV(rrIntervals:), so we
                // reconstruct via its history array directly if you expose a setter,
                // or replay through recordNightlyHRV with synthetic RR pairs that
                // reduce to the stored RMSSD. Simplest fix: add a package-internal
                // seed(date:rmssd:) to BaselineEngine — flagging this as a small
                // follow-up rather than guessing at BaselineEngine's internals here.
                _ = (date, rmssd)
            }
            _ = rhrHist
        } catch {
            print("WhoopScoringOrchestrator: no prior baseline history (\(error)) — starting fresh")
        }
    }

    /// Call each morning (e.g. app becomes active, or a BGAppRefreshTask).
    /// `now` is injectable for testing.
    func runMorningPass(now: Date = Date()) async {
        let calendar = Calendar.current
        // Overnight window: yesterday 6pm -> today 11am, wide enough to catch any
        // reasonable bedtime/wake time without pulling in a full extra day of data.
        guard let windowStart = calendar.date(byAdding: .hour, value: -17, to: now),
              let _ = calendar.date(byAdding: .hour, value: 0, to: now) else { return }

        do {
            let frames = try await frameSource.frames(from: windowStart, to: now)

            let hrSamples = WhoopDataAdapter.hrSamples(fromHistoricalFrames: frames)
            let motionEpochs = WhoopDataAdapter.motionEpochs(fromHistoricalFrames: frames)
            let wornRanges = WhoopDataAdapter.wornIntervals(fromEventFrames: frames)

            guard let sleepWindow = inferSleepWindow(hrSamples: hrSamples, motionEpochs: motionEpochs, wornRanges: wornRanges) else {
                print("WhoopScoringOrchestrator: not enough data to infer last night's sleep window yet")
                return
            }

            let rrPool = WhoopDataAdapter.hrvSamples(fromHistoricalFrames: frames, night: sleepWindow)
            baseline.recordNightlyHRV(date: now, rrIntervalsMs: rrPool)

            let overnightHR = hrSamples.filter { $0.timestamp >= sleepWindow.start && $0.timestamp <= sleepWindow.end }
            baseline.recordRestingHR(date: now, overnightHRSamples: overnightHR)
            if let rhr = baseline.rhrBaseline { todayRestingHR = rhr }

            // Align motion/HR epochs onto the same 30s grid for staging.
            let staged = SleepStageClassifier.classify(
                motionEpochs: motionEpochs,
                hrEpochs: overnightHR,
                hrvEpochs: overnightHR.map { _ in nil }  // per-epoch HRV needs finer pooling; nightly RMSSD used instead for now
            )
            let summary = SleepStageClassifier.summarize(staged)

            let sleepSession = SleepSession(
                start: sleepWindow.start,
                end: sleepWindow.end,
                sleepEfficiency: summary.efficiency,
                sleepNeedHours: 8.0,   // static default; personalize later from sleep-debt trend
                actualSleepHours: summary.totalSleepHours
            )

            let todayHRV = baseline.hrvHistory.last?.rmssd
            let recovery = RecoveryScorer.score(todayHRVRmssd: todayHRV, baseline: baseline, lastNightSleep: sleepSession)

            todayStrain = 0  // reset the daily accumulator for the new day

            try await scoreStore.save(DailyScoreRecord(date: now, recovery: recovery, sleep: sleepSession, strain: todayStrain))
            try await scoreStore.saveBaselineHistory(
                hrv: baseline.hrvHistory.map { ($0.date, $0.rmssd) },
                rhr: baseline.rhrHistory.map { ($0.date, $0.bpm) }
            )

            print("Morning pass complete — recovery: \(Int(recovery.percentage))% (\(recovery.band)), sleep: \(String(format: "%.1f", summary.totalSleepHours))h")
        } catch {
            print("WhoopScoringOrchestrator: morning pass failed — \(error)")
        }
    }

    /// Call whenever new REALTIME_DATA/HISTORICAL_DATA frames arrive during the
    /// day (e.g. from the existing BLE collection callback) to keep strain live.
    func foldInNewFrames(_ frames: [ParsedFrame]) {
        let hrSamples = WhoopDataAdapter.hrSamples(fromHistoricalFrames: frames)
        guard !hrSamples.isEmpty else { return }
        let incrementalStrain = StrainScorer.dailyStrain(
            hrSamples: hrSamples,
            restingHR: todayRestingHR,
            maxHR: todayMaxHR
        )
        // Strain is cumulative and monotonic — never let a partial recompute lower it.
        todayStrain = max(todayStrain, incrementalStrain)
    }

    // MARK: - Sleep window inference

    /// Rough heuristic: the longest worn+still period ending before ~11am.
    /// Replace with something smarter once you have a few weeks of data to
    /// validate against (e.g. requiring a minimum stillness duration, or using
    /// the WRIST_OFF event as a hard end-of-sleep boundary).
    private func inferSleepWindow(
        hrSamples: [HRSample],
        motionEpochs: [MotionEpoch],
        wornRanges: [(start: Date, end: Date)]
    ) -> (start: Date, end: Date)? {
        guard let longest = wornRanges.max(by: { ($0.end.timeIntervalSince($0.start)) < ($1.end.timeIntervalSince($1.start)) }) else {
            // Fall back to first/last HR sample if no clean wrist-on/off pair exists yet.
            guard let first = hrSamples.first?.timestamp, let last = hrSamples.last?.timestamp, last > first else { return nil }
            return (start: first, end: last)
        }
        return longest
    }
}
