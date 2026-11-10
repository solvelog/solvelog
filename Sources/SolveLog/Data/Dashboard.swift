// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// Builds the JSON blob the dashboard page renders (`window.render(data)`).
enum Dashboard {
    static func payload(_ db: Database) throws -> [String: Any] {
        Ratings.backfillOffline(db)

        // Platforms with an official solved list (Luogu practice page) use it for the solved count.
        var official: [String: Set<String>] = [:]
        for r in try db.query("SELECT oj, problem_id FROM official_solved") {
            if let oj = r[0] as? String, let p = r[1] as? String { official[oj, default: []].insert(p) }
        }

        var summary: [[String: Any]] = []
        for r in try db.query("""
            SELECT oj, COUNT(*), SUM(verdict='AC'), COUNT(DISTINCT CASE WHEN verdict='AC' THEN problem_id END), MAX(submit_time)
            FROM submissions GROUP BY oj ORDER BY COUNT(*) DESC
            """) {
            let oj = r[0] as? String ?? ""
            var row: [String: Any] = ["oj": oj, "total": r[1] ?? 0, "ac": r[2] ?? 0, "solved": r[3] ?? 0, "last": r[4] ?? NSNull()]
            if let o = official[oj] { row["solved"] = o.count; row["solved_source"] = "official" }
            // Imported from pages. Project Euler only has solved problems (its rows are placeholders),
            // Luogu has whatever record pages the user imported.
            if Platform(rawValue: oj)?.pageImport == true {
                row["page_import"] = true
                if oj == Platform.projecteuler.rawValue { row["solved_only"] = true }
            }
            summary.append(row)
        }
        // Practice page imported but no record pages yet: still show the platform
        for (oj, set) in official where !summary.contains(where: { ($0["oj"] as? String) == oj }) {
            summary.append(["oj": oj, "total": 0, "ac": 0, "solved": set.count, "last": NSNull(),
                            "solved_source": "official", "page_import": true, "solved_only": true])
        }
        // Problems tried but not solved (Luogu practice page)
        for r in try db.query("SELECT oj, COUNT(*) FROM official_attempted GROUP BY oj") {
            if let oj = r[0] as? String, let i = summary.firstIndex(where: { ($0["oj"] as? String) == oj }) {
                summary[i]["attempted"] = r[1] ?? 0
            }
        }

        let since = Int(Date().timeIntervalSince1970) - 400 * 86400
        let tzOffset = TimeZone.current.secondsFromGMT()
        let daily = try db.query("""
            SELECT date(submit_time + ?, 'unixepoch') d, oj, COUNT(*), SUM(verdict='AC')
            FROM submissions WHERE submit_time >= ? GROUP BY d, oj
            """, [tzOffset, since]).map { ["date": $0[0] ?? "", "oj": $0[1] ?? "", "total": $0[2] ?? 0, "ac": $0[3] ?? 0] }

        let recent = try db.query("""
            SELECT oj, problem_id, problem_title, verdict, score, language, submit_time, url, user
            FROM submissions WHERE submit_time IS NOT NULL ORDER BY submit_time DESC LIMIT 300
            """).map { r -> [String: Any] in
                let keys = ["oj", "problem_id", "title", "verdict", "score", "language", "time", "url", "user"]
                var d: [String: Any] = [:]
                for (k, v) in zip(keys, r) { d[k] = v ?? NSNull() }
                return d
            }

        var solved: [(String, String)] = try db.query("""
            SELECT DISTINCT oj, problem_id FROM submissions WHERE verdict='AC' AND problem_id IS NOT NULL
            """).compactMap { r in
                guard let oj = r[0] as? String, let p = r[1] as? String, official[oj] == nil else { return nil }
                return (oj, p)
            }
        for (oj, ps) in official { solved += ps.sorted().map { (oj, $0) } }

        var byKey: [String: [String: Double]] = [:]
        for r in try db.query("SELECT oj, problem_id, source, rating FROM problem_ratings") {
            guard let oj = r[0] as? String, let p = r[1] as? String, let s = r[2] as? String else { continue }
            let v = (r[3] as? Double) ?? (r[3] as? Int).map(Double.init)
            if let v = v { byKey["\(oj)|\(p)", default: [:]][s] = v }
        }
        let cols = ["oj", "pid", "cf", "ken", "clist", "luogu", "pe", "cc"]
        let rated: [[Any]] = solved.map { oj, p in
            let m = byKey["\(oj)|\(p)"] ?? [:]
            return [oj, p] + cols.dropFirst(2).map { m[$0].map { $0 as Any } ?? NSNull() }
        }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: db.url.path))?[.modificationDate] as? Date
        return ["summary": summary, "daily": daily, "recent": recent, "rated_cols": cols, "rated": rated,
                "accounts": [], "db_mtime": mtime.map { Int($0.timeIntervalSince1970) } ?? NSNull(),
                "configured": SettingsStore.shared.configuredPlatforms().map { $0.rawValue }]
    }
}
