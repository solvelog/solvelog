// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// Problem difficulty sources, each cached on disk:
///   cf    – Codeforces problemset.problems          (1 request)
///   ken   – AtCoder Problems difficulty model         (1 request)
///   cc    – CodeChef practice list difficulty_rating  (~11 requests)
///   clist – clist.by problem ratings, optional API key (~45 requests, 10/min limit)
///   luogu – Luogu practice page (imported from the page the user opens, see LuoguImport)
///   pe    – Project Euler level (fetched by ProjectEulerSync)
enum Ratings {
    static var cacheDir: URL { SettingsStore.shared.directory.appendingPathComponent("cache", isDirectory: true) }
    static func cacheURL(_ name: String) -> URL { cacheDir.appendingPathComponent(name) }

    static func age(_ url: URL) -> TimeInterval {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return .infinity }
        return Date().timeIntervalSince(d)
    }

    static func readCache(_ url: URL) -> [String: Double] {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    static func writeCache(_ url: URL, _ table: [String: Double]) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: table) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: - table loaders (network only when the cache is older than maxAge)

    static func codeforces(maxAge: TimeInterval) async -> [String: Double] {
        let url = cacheURL("codeforces_problemset.json")
        if age(url) < maxAge { return readCache(url) }
        do {
            let obj = try await HTTP.json(HTTP.url("https://codeforces.com/api/problemset.problems"))
            let probs = ((obj as? [String: Any])?["result"] as? [String: Any])?["problems"] as? [[String: Any]] ?? []
            var t: [String: Double] = [:]
            for p in probs { if let c = p["contestId"] as? Int, let i = p["index"] as? String, let r = p["rating"] as? NSNumber { t["\(c)\(i)"] = r.doubleValue } }
            if !t.isEmpty { writeCache(url, t) }
            return t.isEmpty ? readCache(url) : t
        } catch { SyncLog.shared.write("  could not fetch Codeforces ratings: \(error.localizedDescription)"); return readCache(url) }
    }

    static func atcoder(maxAge: TimeInterval) async -> [String: Double] {
        let url = cacheURL("atcoder_difficulty.json")
        if age(url) < maxAge { return readCache(url) }
        do {
            let obj = try await HTTP.json(HTTP.url("https://kenkoooo.com/atcoder/resources/problem-models.json"))
            var t: [String: Double] = [:]
            for (k, v) in obj as? [String: Any] ?? [:] { if let d = (v as? [String: Any])?["difficulty"] as? NSNumber { t[k] = d.doubleValue } }
            if !t.isEmpty { writeCache(url, t) }
            return t.isEmpty ? readCache(url) : t
        } catch { SyncLog.shared.write("  could not fetch AtCoder difficulty: \(error.localizedDescription)"); return readCache(url) }
    }

    static func codechef(maxAge: TimeInterval) async -> [String: Double] {
        let url = cacheURL("codechef_difficulty.json")
        if age(url) < maxAge { return readCache(url) }
        var t: [String: Double] = [:], page = 0
        let headers = ["X-Requested-With": "XMLHttpRequest", "Referer": "https://www.codechef.com/practice"]
        do {
            while true {
                let obj = try await HTTP.json(HTTP.url("https://www.codechef.com/api/list/problems",
                    ["page": page, "limit": 2000, "sort_by": "difficulty_rating", "sort_order": "asc"]), headers: headers)
                let d = obj as? [String: Any] ?? [:]
                let items = d["data"] as? [[String: Any]] ?? []
                for x in items {
                    if let code = x["code"] as? String, let v = Double("\(x["difficulty_rating"] ?? "")"), v > 0 { t[code] = v }
                }
                page += 1
                let count = Int("\(d["count"] ?? 0)") ?? 0
                if items.isEmpty || page * 2000 >= count { break }
                try await HTTP.pause(3)
            }
        } catch { SyncLog.shared.write("  could not fetch CodeChef difficulty: \(error.localizedDescription)") }
        if t.isEmpty { return readCache(url) }
        writeCache(url, t)
        return t
    }

    static let clistResources = ["codeforces": "codeforces.com", "atcoder": "atcoder.jp", "luogu": "luogu.com.cn",
                                 "codechef": "codechef.com", "uoj": "uoj.ac"]

    /// Maps a clist problem URL to the problem id SolveLog stores for that judge.
    static func clistProblemId(_ oj: String, _ url: String) -> String? {
        switch oj {
        case "codeforces":
            guard let g = url.matches(#"/(?:contest|gym)/(\d+)/problem/([A-Za-z0-9]+)"#).first, let c = g[1], let i = g[2] else { return nil }
            return c + i.uppercased()
        case "atcoder": return url.firstMatch(#"/contests/[^/]+/tasks/([^/?#]+)"#)
        case "luogu": return url.firstMatch(#"/problem/([A-Za-z]+\d+)"#)
        case "codechef": return url.firstMatch(#"/problems/([A-Za-z0-9_]+)"#)
        case "uoj": return url.firstMatch(#"uoj\.ac/(?:contest/\d+/)?problem/(\d+)"#)
        default: return nil
        }
    }

    /// clist.by ratings for every judge we have data for. Weekly; needs username + API key.
    static func clist(_ db: Database, force: Bool = false) async throws {
        let s = SettingsStore.shared
        guard !s.settings.clistUsername.isEmpty, let key = s.clistAPIKey else { return }
        let url = cacheURL("clist_ratings.json")
        var table: [String: Double]
        if !force && age(url) < 7 * 86400 {
            table = readCache(url)
        } else {
            table = [:]
            let headers = ["Authorization": "ApiKey \(s.settings.clistUsername):\(key)"]
            for (oj, resource) in clistResources.sorted(by: { $0.key < $1.key }) {
                guard db.scalarInt("SELECT 1 FROM submissions WHERE oj=? LIMIT 1", [oj]) != nil else { continue }
                var offset = 0, got = 0
                while true {
                    let obj = try await HTTP.json(HTTP.url("https://clist.by/api/v4/problem/",
                        ["resource": resource, "limit": 1000, "offset": offset, "order_by": "id"]), headers: headers)
                    let objs = (obj as? [String: Any])?["objects"] as? [[String: Any]] ?? []
                    for o in objs {
                        guard let r = (o["rating"] as? NSNumber)?.doubleValue,
                              let pid = clistProblemId(oj, (o["url"] as? String) ?? (o["href"] as? String) ?? "") else { continue }
                        table["\(oj)|\(pid)"] = r; got += 1
                    }
                    offset += objs.count
                    if objs.count < 1000 { break }
                    try await HTTP.pause(6.5)   // free tier: 10 requests per minute
                }
                SyncLog.shared.write("  clist: \(got) ratings from \(resource)")
                try await HTTP.pause(6.5)
            }
            writeCache(url, table)
        }
        try db.setRatings(table.map { k, v in
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : nil, "clist", v)
        })
    }

    // MARK: - applying tables

    static func applyCodeChef(_ db: Database) async throws {
        let t = await codechef(maxAge: 30 * 86400)
        let pids = try db.query("SELECT DISTINCT problem_id FROM submissions WHERE oj='codechef'").compactMap { $0[0] as? String }
        try db.setRatings(pids.map { ("codechef", $0, "cc", t[$0]) })
    }

    static func unratedSolved(_ db: Database, _ oj: String, _ source: String) -> [String] {
        ((try? db.query("""
            SELECT DISTINCT s.problem_id FROM submissions s
            WHERE s.oj=? AND s.verdict='AC' AND s.problem_id IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM problem_ratings r WHERE r.oj=s.oj AND r.problem_id=s.problem_id AND r.source=?)
            """, [oj, source])) ?? []).compactMap { $0[0] as? String }
    }

    /// After a sync: fill in difficulties for newly solved problems. Each table is re-downloaded only
    /// if something is missing *and* the cache is older than a minimum age (some problems never get rated).
    static func refreshMissing(_ db: Database) async {
        let jobs: [(String, String, TimeInterval, (TimeInterval) async -> [String: Double])] = [
            ("codeforces", "cf", 86400, { await codeforces(maxAge: $0) }),
            ("atcoder", "ken", 86400, { await atcoder(maxAge: $0) }),
            ("codechef", "cc", 3 * 86400, { await codechef(maxAge: $0) }),
        ]
        for (oj, src, minAge, load) in jobs {
            let missing = unratedSolved(db, oj, src)
            guard !missing.isEmpty else { continue }
            let t = await load(minAge)
            let got: [(String, String?, String, Double?)] = missing.compactMap { p in t[p].map { (oj, p, src, $0) } }
            try? db.setRatings(got)
            if !got.isEmpty { SyncLog.shared.write("[ratings] \(oj): filled \(got.count) of \(missing.count) unrated solved problems") }
        }
    }

    /// Cheap, offline: copy ratings embedded in stored submissions (CF rating, Luogu difficulty, PE level).
    static func backfillOffline(_ db: Database) {
        try? db.exec("""
            INSERT OR IGNORE INTO problem_ratings (oj, problem_id, source, rating)
              SELECT 'projecteuler', problem_id, 'pe', score FROM submissions WHERE oj='projecteuler' AND score IS NOT NULL;
            INSERT OR IGNORE INTO problem_ratings (oj, problem_id, source, rating)
              SELECT oj, problem_id, 'cf', json_extract(raw, '$.problem.rating') FROM submissions
              WHERE oj='codeforces' AND problem_id IS NOT NULL AND json_extract(raw, '$.problem.rating') IS NOT NULL;
            INSERT OR IGNORE INTO problem_ratings (oj, problem_id, source, rating)
              SELECT oj, problem_id, 'luogu', json_extract(raw, '$.problem.difficulty') FROM submissions
              WHERE oj='luogu' AND problem_id IS NOT NULL AND json_extract(raw, '$.problem.difficulty') IS NOT NULL;
            """)
    }
}
