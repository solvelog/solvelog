// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// CodeChef public "recent activity" endpoint (no login). Times on the page are IST, day/month/year.
enum CodeChefSync {
    static let ist = TimeZone(secondsFromGMT: 5 * 3600 + 1800)!
    static let verdicts: [(String, String)] = [("partially", "PARTIAL"), ("accepted", "AC"), ("wrong", "WA"),
        ("time limit", "TLE"), ("memory", "MLE"), ("runtime", "RE"), ("compil", "CE"), ("internal", "UKE"),
        ("running", "JUDGING"), ("waiting", "PENDING"), ("queue", "PENDING")]

    static func run(_ db: Database, handles: [String], full: Bool) async throws -> Int {
        let known = full ? [] : try db.knownFinalIds("codechef")
        let headers = ["X-Requested-With": "XMLHttpRequest", "Referer": "https://www.codechef.com/"]
        var total = 0
        for (i, handle) in handles.enumerated() {
            if i > 0 { try await HTTP.pause(3) }
            let stop = db.historyComplete("codechef", handle) ? known : []
            var page = 0, n = 0
            while true {
                let obj = try await HTTP.json(HTTP.url("https://www.codechef.com/recent/user",
                                                       ["page": page, "user_handle": handle]), headers: headers)
                guard let d = obj as? [String: Any] else { throw HTTPError.badResponse("CodeChef: unexpected response") }
                let rows = parse(d["content"] as? String ?? "", handle: handle, now: Date())
                try db.upsert(rows)
                n += rows.count
                let maxPage = d["max_page"] as? Int ?? 0
                if page == 0 && rows.isEmpty { SyncLog.shared.write("  \(handle): no submissions (is the handle right?)") }
                if rows.isEmpty || page + 1 >= maxPage {
                    try db.markComplete("codechef", handle)
                    break
                }
                if rows.contains(where: { stop.contains($0.id) }) { break }
                page += 1
                try await HTTP.pause(3)   // CodeChef rate-limits aggressively
            }
            SyncLog.shared.write("  \(handle): \(n) submissions")
            total += n
        }
        try await Ratings.applyCodeChef(db)
        return total
    }

    static func parse(_ content: String, handle: String, now: Date) -> [Submission] {
        var rows: [Submission] = [], seen: [String: Int] = [:]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = ist
        fmt.dateFormat = "hh:mm a dd/MM/yy"
        for m in content.matches(#"<tr\s*>(.*?)</tr>"#) {
            guard let tr = m[1], let prob = tr.matches(#"href='(?:/([A-Za-z0-9_]+))?/problems/([^'/]+)'"#).first,
                  let code = prob[2] else { continue }
            let timeText = tr.firstMatch(#"<td\s+title='([^']*)'>\s*<span class='tooltips'>"#) ?? ""
            var ts = fmt.date(from: timeText).map { Int($0.timeIntervalSince1970) }
            if ts == nil, let g = timeText.matches(#"(\d+)\s*(sec|min|hour|day)"#).first, let k = Int(g[1] ?? "") {
                let unit = ["sec": 1, "min": 60, "hour": 3600, "day": 86400][g[2] ?? ""] ?? 0
                ts = Int(now.timeIntervalSince1970) - k * unit
            }
            let vt = tr.firstMatch(#"<span title='([^']*)'"#)
            let low = (vt ?? "").lowercased()
            let verdict = verdicts.first { low.contains($0.0) }?.1 ?? vt
            let score = tr.firstMatch(#"\((\d+(?:\.\d+)?)\)"#).flatMap(Double.init)
            let lang = tr.firstMatch(#"<td\s+title='([^']*)'>[^<]*</td><td class="centered""#)
            let sol = tr.firstMatch(#"/viewsolution/(\d+)"#)
            var sid: String
            if let s = sol { sid = s } else {
                // Hidden solutions have no id: derive a stable one, numbering duplicates within a page.
                let base = "x\(code)-\(ts.map(String.init) ?? "")-\(verdict ?? "")"
                seen[base, default: 0] += 1
                sid = seen[base]! == 1 ? base : "\(base)-\(seen[base]!)"
            }
            rows.append(Submission(oj: "codechef", id: sid, user: handle, problemId: code, problemTitle: nil,
                                   contestId: prob[1], verdict: verdict, rawVerdict: vt, score: score, timeMs: nil,
                                   memoryKb: nil, language: lang, codeLength: nil, submitTime: ts,
                                   url: sol.map { "https://www.codechef.com/viewsolution/\($0)" } ?? "https://www.codechef.com/problems/\(code)",
                                   raw: jsonString(["html": String(tr.trimmed.prefix(2000))])))
        }
        return rows
    }
}
