// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// Codeforces official API (no login). Several handles are merged; team submissions are stored once.
enum CodeforcesSync {
    static let verdicts = ["OK": "AC", "WRONG_ANSWER": "WA", "TIME_LIMIT_EXCEEDED": "TLE",
                           "MEMORY_LIMIT_EXCEEDED": "MLE", "RUNTIME_ERROR": "RE", "COMPILATION_ERROR": "CE",
                           "IDLENESS_LIMIT_EXCEEDED": "ILE", "PARTIAL": "PARTIAL", "TESTING": "JUDGING",
                           "SKIPPED": "SKIPPED", "CHALLENGED": "HACKED", "REJECTED": "REJECTED"]

    static func run(_ db: Database, handles: [String], full: Bool) async throws -> Int {
        let known = full ? [] : try db.knownFinalIds("codeforces")
        var total = 0
        for (i, handle) in handles.enumerated() {
            if i > 0 { try await HTTP.pause(2) }
            let stop = db.historyComplete("codeforces", handle) && !full ? known : []
            let n = try await syncHandle(db, handle, stop: stop)
            SyncLog.shared.write("  \(handle): \(n) submissions")
            total += n
        }
        return total
    }

    private static func syncHandle(_ db: Database, _ handle: String, stop: Set<String>) async throws -> Int {
        // Incremental runs start with a small page; a full history run uses big pages.
        var from = 1, count = stop.isEmpty ? 1000 : 50, total = 0
        while true {
            let obj = try await HTTP.json(HTTP.url("https://codeforces.com/api/user.status",
                                                   ["handle": handle, "from": from, "count": count]))
            guard let d = obj as? [String: Any], d["status"] as? String == "OK",
                  let batch = d["result"] as? [[String: Any]] else {
                let msg = ((obj as? [String: Any])?["comment"] as? String) ?? "unexpected response"
                throw HTTPError.badResponse("Codeforces: \(msg)")
            }
            var rows: [Submission] = [], ratings: [(String, String?, String, Double?)] = [], hitKnown = false
            for x in batch {
                let sid = "\(x["id"] ?? "")"
                if stop.contains(sid) { hitKnown = true }
                let p = x["problem"] as? [String: Any] ?? [:]
                let cid = (x["contestId"] as? Int) ?? (p["contestId"] as? Int)
                let index = p["index"] as? String ?? ""
                let pid = "\(cid.map(String.init) ?? "")\(index)"
                let v = x["verdict"] as? String
                let gym = (cid ?? 0) >= 100000
                let members = ((x["author"] as? [String: Any])?["members"] as? [[String: Any]] ?? []).compactMap { $0["handle"] as? String }
                rows.append(Submission(
                    oj: "codeforces", id: sid, user: members.count > 1 ? members.joined(separator: "+") : handle,
                    problemId: pid, problemTitle: p["name"] as? String, contestId: cid.map(String.init),
                    verdict: v.map { verdicts[$0] ?? $0 } ?? "PENDING", rawVerdict: v, score: p["points"] as? Double,
                    timeMs: x["timeConsumedMillis"] as? Int, memoryKb: (x["memoryConsumedBytes"] as? Int).map { $0 / 1024 },
                    language: x["programmingLanguage"] as? String, codeLength: nil,
                    submitTime: x["creationTimeSeconds"] as? Int,
                    url: cid.map { "https://codeforces.com/\(gym ? "gym" : "contest")/\($0)/submission/\(sid)" },
                    raw: jsonString(x)))
                ratings.append(("codeforces", pid, "cf", (p["rating"] as? NSNumber)?.doubleValue))
            }
            try db.upsert(rows)
            try db.setRatings(ratings)
            total += rows.count
            if batch.count < count {
                try db.markComplete("codeforces", handle)
                break
            }
            if hitKnown { break }
            from += count
            count = 1000
            try await HTTP.pause(2)   // API limit: one call every 2 seconds
        }
        return total
    }
}
