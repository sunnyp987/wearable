import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Deterministic JSON for an event payload (sorted keys so the same payload always
    /// serializes byte-identically — important for the natural-key dedupe and parity).
    static func encodePayload(_ payload: [String: ParsedValue]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Insert or update a device row (natural key = id).
    public func upsertDevice(id: String, mac: String?, name: String?) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = excluded.mac,
                    name = excluded.name,
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    /// Idempotent upsert of decoded streams by natural key. Returns the number of rows
    /// ACTUALLY inserted per stream (0 for rows that already existed).
    ///
    /// - Parameter markSynced: When `true`, freshly-inserted rows get `synced = 1` so the Uploader
    ///   won't re-upload them. Use it ONLY for rows that are ALREADY on the server (e.g. ServerSync
    ///   pulling server-side rows back to the phone). Locally-collected rows (Collector, Backfiller)
    ///   must keep the default `false` (synced = 0) so they get uploaded.
    ///
    ///   IMPORTANT: every decoded table uses `ON CONFLICT ... DO NOTHING`, so a conflicting row's
    ///   existing `synced` value is NEVER clobbered. A row that was already uploaded (synced = 1)
    ///   stays synced even if a later `insert(..., markSynced: false)` re-presents the same key, and
    ///   a row still pending upload (synced = 0) is never silently marked synced by a pull. The
    ///   `synced` value is therefore decided ONLY at first insert.
    @discardableResult
    public func insert(_ streams: Streams, deviceId: String, markSynced: Bool = false) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        let synced = markSynced ? 1 : 0
        return try syncWrite { db in
            var hr = 0, rr = 0, ev = 0, bat = 0
            var spo2 = 0, skin = 0, resp = 0, grav = 0
            for s in streams.hr {
                try db.execute(sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """, arguments: [deviceId, s.ts, s.bpm, synced])
                hr += db.changesCount
            }
            for r in streams.rr {
                try db.execute(sql: """
                    INSERT INTO rrInterval (deviceId, ts, rrMs, synced) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, rrMs) DO NOTHING
                    """, arguments: [deviceId, r.ts, r.rrMs, synced])
                rr += db.changesCount
            }
            for e in streams.events {
                let json = try WhoopStore.encodePayload(e.payload)
                try db.execute(sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON, synced) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, kind) DO NOTHING
                    """, arguments: [deviceId, e.ts, e.kind, json, synced])
                ev += db.changesCount
            }
            for b in streams.battery {
                try db.execute(sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, charging, synced) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """, arguments: [deviceId, b.ts, b.soc, b.mv, b.charging, synced])
                bat += db.changesCount
            }
            for s in streams.spo2 {
                try db.execute(sql: """
                    INSERT INTO spo2Sample (deviceId, ts, red, ir, synced) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """, arguments: [deviceId, s.ts, s.red, s.ir, synced])
                spo2 += db.changesCount
            }
            for s in streams.skinTemp {
                try db.execute(sql: """
                    INSERT INTO skinTempSample (deviceId, ts, raw, synced) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """, arguments: [deviceId, s.ts, s.raw, synced])
                skin += db.changesCount
            }
            for s in streams.resp {
                try db.execute(sql: """
                    INSERT INTO respSample (deviceId, ts, raw, synced) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """, arguments: [deviceId, s.ts, s.raw, synced])
                resp += db.changesCount
            }
            for s in streams.gravity {
                try db.execute(sql: """
                    INSERT INTO gravitySample (deviceId, ts, x, y, z, synced) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """, arguments: [deviceId, s.ts, s.x, s.y, s.z, synced])
                grav += db.changesCount
            }
            return (hr, rr, ev, bat, spo2, skin, resp, grav)
        }
    }

    // MARK: - Test helpers

public func storageStats_rowCountsForTest() async throws
    -> (hr: Int, rr: Int, events: Int, battery: Int,
        spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
    try syncRead { db in
        let hr: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
        let rr: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
        let events: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
        let battery: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
        let spo2: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spo2Sample") ?? 0
        let skinTemp: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skinTempSample") ?? 0
        let resp: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM respSample") ?? 0
        let gravity: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gravitySample") ?? 0
        return (hr, rr, events, battery, spo2, skinTemp, resp, gravity)
    }
}

    public func deviceRowForTest(id: String) async throws -> (mac: String?, name: String?)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return (row["mac"], row["name"])
        }
    }
}
