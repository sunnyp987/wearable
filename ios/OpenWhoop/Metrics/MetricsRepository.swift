import Foundation
import SwiftUI
import WhoopStore

// MARK: - MetricsRepository
//
// View-facing read facade over the local MetricsCache (WhoopStore tables dailyMetric +
// sleepSession).
//
// UPDATED: originally this read ONLY server-computed values via ServerSync.pullDerived().
// Since no server is configured here (serverSync stays nil without WHOOP_BASE_URL/API key),
// that path was a no-op — the cache was never populated. WhoopScoringOrchestrator now computes
// recovery/strain/sleep/HRV locally on-device and writes into the SAME dailyMetric/sleepSession
// cache tables, so every read method below (today, lastNight, daily(), sleepSessions(), etc.)
// keeps working unchanged. serverSync is left in place and still called if you ever do configure
// a server — the two sources write to the same tables, last write wins, so nothing conflicts.
//
// LAZY-OPEN DESIGN: The synchronous init() does NOT open the on-disk store (WhoopStore.init
// is async). Instead, ensureOpen() is called at the top of every async method and opens the
// store + builds ServerSync + WhoopScoringOrchestrator on the first call. This lets AppRoot
// create the repo synchronously (as a @StateObject) and always inject a non-nil env object.

@MainActor
final class MetricsRepository: ObservableObject {
    @Published private(set) var today: DailyMetric?            // most-recent cached daily row
    @Published private(set) var lastNight: CachedSleepSession? // most-recent cached sleep session
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?

    // Injected directly (test path): store + sync are ready immediately; skip ensureOpen.
    private var store: WhoopStore?
    private var serverSync: ServerSync?
    private var orchestrator: WhoopScoringOrchestrator?
    private let deviceId: String

    // Lazy-open state (app path).
    private var _alreadyOpen = false
    private var _openTask: Task<Void, Never>?

    // MARK: - Synchronous init (app path — store not yet open)

    init(deviceId: String = "my-whoop") {
        self.deviceId = deviceId
        self.store = nil
        self.serverSync = nil
        self.orchestrator = nil
        self._alreadyOpen = false
    }

    // MARK: - Designated init (test path — store + sync injected)

    init(store: WhoopStore, serverSync: ServerSync?, deviceId: String) {
        self.store = store
        self.serverSync = serverSync
        self.orchestrator = WhoopScoringOrchestrator(store: store, deviceId: deviceId)
        self.deviceId = deviceId
        self._alreadyOpen = true   // already wired — no lazy open needed
    }

    // MARK: - Lazy open (app path)

    private func ensureOpen() async {
        if _alreadyOpen, store != nil { return }
        if let openTask = _openTask { await openTask.value; return }
        let task = Task { @MainActor [self] in
            guard let path = try? StorePaths.defaultDatabasePath(),
                  let openedStore = try? await WhoopStore(path: path) else {
                lastError = "Could not open local database"
                _openTask = nil
                return
            }
            store = openedStore
            serverSync = AppConfig.uploaderConfig(deviceId: deviceId)
                .map { ServerSync(config: $0, store: openedStore, deviceId: deviceId) }

            let newOrchestrator = WhoopScoringOrchestrator(store: openedStore, deviceId: deviceId)
            await newOrchestrator.restoreBaselines()
            orchestrator = newOrchestrator

            _alreadyOpen = true
        }
        _openTask = task
        await task.value
    }

    // MARK: - App factory (kept for backward-compat; AppRoot now prefers init())

    static func makeDefault(deviceId: String = "my-whoop") async -> MetricsRepository? {
        guard let path = try? StorePaths.defaultDatabasePath(),
              let store = try? await WhoopStore(path: path) else { return nil }
        let sync = AppConfig.uploaderConfig(deviceId: deviceId)
            .map { ServerSync(config: $0, store: store, deviceId: deviceId) }
        return MetricsRepository(store: store, serverSync: sync, deviceId: deviceId)
    }

    // MARK: - Load from cache (no network, no computation)

    func load() async {
        await ensureOpen()
        guard let store else { return }

        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"

        if let start = cal.date(byAdding: .day, value: -14, to: now) {
            let fromDay = fmt.string(from: start)
            let toDay = fmt.string(from: now)
            today = (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay))?.last
        }

        let windowStart = Int(now.timeIntervalSince1970) - 14 * 86_400
        let windowEnd   = Int(now.timeIntervalSince1970) + 86_400
        lastNight = (try? await store.sleepSessions(deviceId: deviceId,
                                                    from: windowStart,
                                                    to: windowEnd,
                                                    limit: 50))?.last
    }

    // MARK: - Refresh: compute locally on-device, optionally also pull from server, then reload

    /// Computes recovery/strain/sleep locally via WhoopScoringOrchestrator (writes into the
    /// dailyMetric/sleepSession cache tables), then — only if a server happens to be configured —
    /// also pulls server-derived values on top, then reloads the @Published properties from cache.
    /// Never throws; safe when orchestrator or serverSync are nil.
    func refresh() async {
        await ensureOpen()
        isRefreshing = true
        lastError = nil

        // Local, on-device computation — the primary path now.
        await orchestrator?.runMorningPass()
        await orchestrator?.refreshTodayStrain()
        if let orchestratorError = orchestrator?.lastError {
            lastError = orchestratorError
        }

        // Optional: only does anything if you've configured a server (WHOOP_BASE_URL/API key).
        await serverSync?.pullDerived()

        await load()
        isRefreshing = false
        lastRefreshedAt = Date()

        if let metric = today, let recovery = metric.recovery {
            RecoveryNotifier.notify(recovery: recovery, forDay: metric.day)
        }
    }

    // MARK: - Range reads for Trends/Sleep tabs

    func daily(fromDay: String, toDay: String) async -> [DailyMetric] {
        await ensureOpen()
        guard let store else { return [] }
        return (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
    }

    func sleepSessions(from: Int, to: Int, limit: Int) async -> [CachedSleepSession] {
        await ensureOpen()
        guard let store else { return [] }
        return (try? await store.sleepSessions(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    // MARK: - Profile (M0.5)

    func getProfile() async -> Profile? {
        await ensureOpen()
        return await serverSync?.getProfile()
    }

    func putProfile(_ profile: Profile) async -> Bool {
        await ensureOpen()
        return await serverSync?.putProfile(profile) ?? false
    }

    // MARK: - Sleep tab reads (M2)

    func sleepDetail() async -> (session: CachedSleepSession, daily: DailyMetric?)? {
        await ensureOpen()
        guard let store else { return nil }

        let now = Int(Date().timeIntervalSince1970)
        let windowStart = now - 14 * 86_400
        let windowEnd   = now + 86_400
        guard let session = (try? await store.sleepSessions(deviceId: deviceId,
                                                            from: windowStart,
                                                            to: windowEnd,
                                                            limit: 50))?.last else { return nil }

        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let endDate = Date(timeIntervalSince1970: TimeInterval(session.endTs))
        let day = fmt.string(from: endDate)

        let daily = (try? await store.dailyMetrics(deviceId: deviceId, from: day, to: day))?.first

        return (session: session, daily: daily)
    }

    func sevenNightSleepWake(nights: Int = 7) async -> [CachedSleepSession] {
        await ensureOpen()
        guard let store else { return [] }

        let now = Int(Date().timeIntervalSince1970)
        let windowStart = now - (nights + 2) * 86_400
        let windowEnd   = now + 86_400
        let sessions = (try? await store.sleepSessions(deviceId: deviceId,
                                                       from: windowStart,
                                                       to: windowEnd,
                                                       limit: nights + 2)) ?? []
        return Array(sessions.suffix(nights))
    }

    // MARK: - Raw HR series (downsampled stream, for Trends card + HeartRateDetailView)

    func hrSeries(fromEpoch: Int, toEpoch: Int, maxPoints: Int) async -> [TrendPoint] {
        await ensureOpen()
        guard let serverSync else { return [] }
        let raw = await serverSync.getHRSeries(fromEpoch: fromEpoch, toEpoch: toEpoch, maxPoints: maxPoints)
        return raw.map { pair in
            TrendPoint(
                id: "\(pair.ts)",
                date: Date(timeIntervalSince1970: TimeInterval(pair.ts)),
                value: Double(pair.bpm)
            )
        }
    }

    // MARK: - Workouts (M5)

    func workouts(from: String, to: String) async -> [Workout] {
        await ensureOpen()
        return await serverSync?.getWorkouts(from: from, to: to) ?? []
    }

    // MARK: - Workout calorie backfill (M7)

    @discardableResult
    func backfillWorkouts(from: String, to: String) async -> Bool {
        await ensureOpen()
        return await serverSync?.backfillWorkouts(from: from, to: to) ?? false
    }
}
