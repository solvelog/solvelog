// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// AtCoder submissions via the AtCoder Problems (kenkoooo) public API.
enum AtCoderSync {
    static func run(_ db: Database, handles: [String], full: Bool) async throws -> Int {
        var total = 0
        for (i, user) in handles.enumerated() {
            if i > 0 { try await HTTP.pause(1.5) }
            // Start from this account's oldest still-judging submission, else its newest one.
            var fromSecond = 0
            if !full {
                fromSecond = db.scalarInt("""
                    SELECT COALESCE(
                      (SELECT MIN(submit_time) FROM submissions WHERE oj='atcoder' AND user=? AND verdict IN ('PENDING','JUDGING')),
                      (SELECT MAX(submit_time) FROM submissions WHERE oj='atcoder' AND user=?))
                    """, [user, user]) ?? 0
            }
            var n = 0
            while true {
                let obj = try await HTTP.json(HTTP.url("https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
                                                       ["user": user, "from_second": fromSecond]))
                guard let batch = obj as? [[String: Any]] else { throw HTTPError.badResponse("AtCoder Problems: unexpected response") }
                let rows: [Submission] = batch.map { x in
                    let res = x["result"] as? String
                    let judging = res == "WJ" || res == "WR" || (res.map { Int($0) != nil } ?? false)
                    return Submission(
                        oj: "atcoder", id: "\(x["id"] ?? "")", user: user, problemId: x["problem_id"] as? String,
                        problemTitle: nil, contestId: x["contest_id"] as? String, verdict: judging ? "JUDGING" : res,
                        rawVerdict: res, score: (x["point"] as? NSNumber)?.doubleValue, timeMs: x["execution_time"] as? Int,
                        memoryKb: nil, language: x["language"] as? String, codeLength: x["length"] as? Int,
                        submitTime: x["epoch_second"] as? Int,
                        url: "https://atcoder.jp/contests/\(x["contest_id"] ?? "")/submissions/\(x["id"] ?? "")",
                        raw: jsonString(x))
                }
                try db.upsert(rows)
                n += rows.count
                if batch.count < 500 { break }
                var next = batch.compactMap { $0["epoch_second"] as? Int }.max() ?? fromSecond
                if next == fromSecond { next += 1 }   // more than 500 submissions in one second
                fromSecond = next
                try await HTTP.pause(1.5)        // kenkoooo asks for >= 1s between requests
            }
            SyncLog.shared.write("  \(user): \(n) submissions")
            total += n
        }
        return total
    }
}
