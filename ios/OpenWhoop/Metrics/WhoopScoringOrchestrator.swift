//
//  WhoopScoringOrchestrator.swift
//  Drop into ios/ alongside the other files.
//
//  REVISED to use the real WhoopStore actor API (Reads.swift + MetricsCache.swift)
//  instead of the placeholder FrameSource/ScoreStore protocols from the earlier
//  version. Persists computed scores into the existing dailyMetric/sleepSession
//  tables via upsertDailyMetrics/upsertSleepSessions — those tables were designed
//  for server-pulled values, but the shape fits our on-device-computed values
//  just as well, so we reuse them and simply never call the server sync path.
//

import Foundation
import WhoopProtocol
import WhoopStore

@MainActor
final class WhoopScoringOrchestrator {

    private let store: WhoopStore
    private let deviceId: String
    private let baseline = BaselineEngine()

    /// Running strain accumulator for "today" — strain never decreases within a day.
    private(set) var todayStrain: Double = 0
    private var todayRestingHR: Double = 50   // sensible default until baseline warms up
    private var todayMaxHR: Double            // Tanaka (208 − 0.7×age) from the local body
                                               // profile when available; 190 default otherwise.

    /// Read-only accessors so other consumers (e.g. local workout auto-detection in
    /// MetricsRepository) can reuse the same personalized HR baseline this orchestrator uses.
    var currentRestingHR: Double { todayRestingHR }
    var currentMaxHR: Double { todayMaxHR }

    /// Set whenever runMorningPass/refreshTodayStrain hits an error, so a caller (e.g.
    /// MetricsRepository) can surface it in the UI instead of it only going to the
    /// debug console — important since there's no Mac/Xcode console available to watch
    /// this live on-device.
    private(set) var lastError: String?

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(store: WhoopStore, deviceId: String) {
        self.store = store
        self.deviceId = deviceId
        self.todayMaxHR = Self.estimatedMaxHR()
    }

    /// Tanaka et al. 2001 (208 − 0.7×age) — a better-fit HRmax estimator than the classic
    /// 220−age rule, used when the user has entered their age in Settings. Falls back to a
    /// fixed 190 when no local profile exists yet (ProfileStorage is local-only UserDefaults,
    /// so this works with no server configured).
    private static func estimatedMaxHR() -> Double {
        guard let age = ProfileStorage.load()?.age, age > 0 else { return 190 }
        return 208.0 - 0.7 * Double(age)
    }

    /// Call once at app launch to restore rolling HRV/RHR baselines from the
    /// last ~14 days of cached daily metrics (avgHrv / restingHr columns).
    func restoreBaselines() async {
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -14, to: Date()) else { return }
        let fromDay = Self.dayFormatter.string(from: start)
        let toDay = Self.dayFormatter.string(from: Date())

        do {
            let history = try await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)
            for metric in history {
                guard let date = Self.dayFormatter.date(from: metric.day) else { continue }
                if let hrv = metric.avgHrv {
                    baseline.seedHRV(date: date, rmssd: hrv)
                }
                if let rhr = metric.restingHr {
                    baseline.seedRestingHR(date: date, bpm: Double(rhr))
                }
            }
            if let rhr = baseline.rhrBaseline { todayRestingHR = rhr }
        } catch {
            print("WhoopScoringOrchestrator: no prior baseline history (\(error)) — starting fresh")
        }
    }

    /// Call each morning (e.g. app becomes active, or a BGAppRefreshTask).
    func runMorningPass(now: Date = Date()) async {
        lastError = nil
        let calendar = Calendar.current
        guard let windowStart = calendar.date(byAdding: .hour, value: -17, to: now) else { return }
        let fromTs = Int(windowStart.timeIntervalSince1970)
        let toTs = Int(now.timeIntervalSince1970)

        do {
            let hrRows = try await store.hrSamples(deviceId: deviceId, from: fromTs, to: toTs, limit: 200_000)
            let gravityRows = try await store.gravitySamples(deviceId: deviceId, from: fromTs, to: toTs, limit: 200_000)
            let eventRows = try await store.events(deviceId: deviceId, from: fromTs, to: toTs, limit: 5_000)

            let hrSamples = WhoopDataAdapter.scoringHRSamples(from: hrRows)
            let motionEpochs = WhoopDataAdapter.motionEpochs(from: gravityRows)
            let wornRanges = WhoopDataAdapter.wornIntervals(from: eventRows)

            guard let sleepWindow = inferSleepWindow(hrSamples: hrSamples, wornRanges: wornRanges) else {
                let latestTs = try? await store.latestHRSampleTs(deviceId: deviceId)
                let latestDateStr: String = {
                    guard let ts = latestTs else { return "none stored" }
                    let date = Date(timeIntervalSince1970: Double(ts))
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
                    fmt.timeZone = TimeZone(identifier: "UTC")
                    return fmt.string(from: date)
                }()
                lastError = "No sleep window found — \(hrRows.count) HR rows, \(gravityRows.count) motion rows, \(eventRows.count) events in the last 17h. Most recent stored HR sample overall: \(latestDateStr)"
                print(lastError!)
                return
            }

            let rrFromTs = Int(sleepWindow.start.timeIntervalSince1970)
            let rrToTs = Int(sleepWindow.end.timeIntervalSince1970)
            let rrRows = try await store.rrIntervals(deviceId: deviceId, from: rrFromTs, to: rrToTs, limit: 200_000)
            let rrRuns = WhoopDataAdapter.rrRuns(from: rrRows)
            baseline.recordNightlyHRV(date: now, rrRuns: rrRuns)

            let overnightHR = hrSamples.filter { $0.timestamp >= sleepWindow.start && $0.timestamp <= sleepWindow.end }
            baseline.recordRestingHR(date: now, overnightHRSamples: overnightHR)
            if let rhr = baseline.rhrBaseline { todayRestingHR = rhr }

            // FIX: motionEpochs previously spanned the full 17h scan window while
            // overnightHR was already filtered to just the sleep window — a length
            // mismatch that tripped SleepStageClassifier's alignment guard and
            // silently returned an empty result (0m sleep, recovery=0 every time).
            let overnightMotion = motionEpochs.filter { $0.start >= sleepWindow.start && $0.start <= sleepWindow.end }

            let staged = SleepStageClassifier.classify(
                windowStart: sleepWindow.start,
                windowEnd: sleepWindow.end,
                motionEpochs: overnightMotion,
                hrEpochs: overnightHR
            )
            let summary = SleepStageClassifier.summarize(staged)

            let sleepSession = SleepSession(
                start: sleepWindow.start,
                end: sleepWindow.end,
                sleepEfficiency: summary.efficiency,
                sleepNeedHours: 8.0,
                actualSleepHours: summary.totalSleepHours
            )

            let todayHRV = baseline.hrvHistory.last?.rmssd
            // The overnight RHR was just recorded into baseline.rhrHistory above (line ~112) —
            // its most recent entry IS tonight's value. Passing it through fixes the recovery
            // score's RHR component, which previously always evaluated to nil (see WhoopScoreEngine).
            let overnightRHR = baseline.rhrHistory.last?.bpm
            let recovery = RecoveryScorer.score(
                todayHRVRmssd: todayHRV,
                todayRestingHR: overnightRHR,
                baseline: baseline,
                lastNightSleep: sleepSession
            )

            todayStrain = 0  // reset the daily accumulator for the new day

            let dayKey = Self.dayFormatter.string(from: now)
            try await store.upsertSleepSessions([
                CachedSleepSession(
                    startTs: Int(sleepWindow.start.timeIntervalSince1970),
                    endTs: Int(sleepWindow.end.timeIntervalSince1970),
                    efficiency: sleepSession.sleepEfficiency,
                    restingHr: Int(todayRestingHR),
                    avgHrv: todayHRV,
                    stagesJSON: nil  // fill in once you want per-stage segments persisted too
                )
            ], deviceId: deviceId)

            try await store.upsertDailyMetrics([
                DailyMetric(
                    day: dayKey,
                    totalSleepMin: summary.totalSleepHours * 60,
                    efficiency: summary.efficiency,
                    deepMin: summary.deepHours * 60,
                    remMin: summary.remHours * 60,
                    lightMin: summary.lightHours * 60,
                    disturbances: nil,
                    restingHr: Int(todayRestingHR),
                    avgHrv: todayHRV,
                    // FIXED: recovery.percentage is already 0-100 scale (RecoveryScorer computes
                    // `* 100`), but DailyMetric.recovery is expected as a 0-1 FRACTION everywhere
                    // it's read (TodayView, DayDetailView, TrendsView all do `recovery * 100` for
                    // display) — storing the already-scaled value made 41% render as 4100%.
                    recovery: recovery.percentage / 100,
                    strain: todayStrain,
                    exerciseCount: nil
                )
            ], deviceId: deviceId)

            print("Morning pass complete — recovery: \(Int(recovery.percentage))% (\(recovery.band)), sleep: \(String(format: "%.1f", summary.totalSleepHours))h")
        } catch {
            lastError = "Morning pass failed: \(error)"
            print(lastError!)
        }
    }

    /// Call whenever new HR data lands during the day (e.g. after a BLE sync)
    /// to keep strain live. Pulls only today's rows.
    func refreshTodayStrain(now: Date = Date()) async {
        let calendar = Calendar.current
        guard let startOfDay = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: now)) else { return }
        do {
            let hrRows = try await store.hrSamples(
                deviceId: deviceId,
                from: Int(startOfDay.timeIntervalSince1970),
                to: Int(now.timeIntervalSince1970),
                limit: 200_000
            )
            let hrSamples = WhoopDataAdapter.scoringHRSamples(from: hrRows)
            guard !hrSamples.isEmpty else { return }
            let computed = StrainScorer.dailyStrain(hrSamples: hrSamples, restingHR: todayRestingHR, maxHR: todayMaxHR)
            todayStrain = max(todayStrain, computed)  // strain is monotonic within a day

            // FIXED: this used to only update the in-memory `todayStrain` property, which
            // nothing else ever read — MetricsRepository.load() reads the persisted dailyMetric
            // row from the store, and runMorningPass() (which always runs right before this,
            // in MetricsRepository.refresh()) writes that row with strain freshly reset to 0.
            // Net effect: the UI's strain value was permanently stuck at 0 after every refresh.
            // Fetch-merge-upsert so this write doesn't clobber the sleep/recovery/HRV fields
            // runMorningPass already wrote for today.
            let dayKey = Self.dayFormatter.string(from: now)
            let existing = (try? await store.dailyMetrics(deviceId: deviceId, from: dayKey, to: dayKey))?.last
            let merged = DailyMetric(
                day: dayKey,
                totalSleepMin: existing?.totalSleepMin,
                efficiency: existing?.efficiency,
                deepMin: existing?.deepMin,
                remMin: existing?.remMin,
                lightMin: existing?.lightMin,
                disturbances: existing?.disturbances,
                restingHr: existing?.restingHr,
                avgHrv: existing?.avgHrv,
                recovery: existing?.recovery,
                strain: todayStrain,
                exerciseCount: existing?.exerciseCount,
                spo2Pct: existing?.spo2Pct,
                skinTempDevC: existing?.skinTempDevC,
                respRateBpm: existing?.respRateBpm
            )
            try? await store.upsertDailyMetrics([merged], deviceId: deviceId)
        } catch {
            print("WhoopScoringOrchestrator: strain refresh failed — \(error)")
        }
    }

    // MARK: - Sleep window inference

    private func inferSleepWindow(
        hrSamples: [ScoringHRSample],
        wornRanges: [(start: Date, end: Date)]
    ) -> (start: Date, end: Date)? {
        guard let longest = wornRanges.max(by: { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }) else {
            guard let first = hrSamples.first?.timestamp, let last = hrSamples.last?.timestamp, last > first else { return nil }
            return (start: first, end: last)
        }
        return longest
    }
}
