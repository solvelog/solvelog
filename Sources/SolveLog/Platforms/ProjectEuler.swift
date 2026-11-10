// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// Project Euler keeps no submission history, only "solved + completion time".
/// Each solved problem becomes one AC record; its difficulty level (0-40) is kept in `score`.
enum ProjectEulerSync {
    static let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                         "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]

    /// Imports the Progress page the user opened in their own browser (sent by the userscript).
    /// SolveLog never requests projecteuler.net itself.
    static func importPage(_ db: Database, html: String, handle: String?, utcOffsetHours: Double) throws -> Int {
        var rows: [Submission] = [], seen = Set<String>()
        let tz = TimeZone(secondsFromGMT: Int(utcOffsetHours * 3600)) ?? .current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        for m in html.matches(#"<td class="[^"]*problem_solved[^"]*">(.*?)</td>"#) {
            guard let cell = m[1], let pid = cell.firstMatch(#"href="/?problem=(\d+)""#), !seen.contains(pid) else { continue }
            seen.insert(pid)   // the page lists each problem twice (by id and by level)
            let lines = cell.strippingTags.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }
            let title = lines.first { $0.hasPrefix("\"") }?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let diff = lines.first { $0.hasPrefix("Difficulty") }
            let level = diff?.firstMatch(#"Level (\d+)"#).flatMap(Double.init)
            var ts: Int?
            if let done = lines.first(where: { $0.hasPrefix("Completed on") }),
               let g = done.matches(#"(\d{1,2}) (\w{3}) (\d{4}), (\d{1,2}):(\d{2})"#).first,
               let day = Int(g[1] ?? ""), let mon = months[g[2] ?? ""], let y = Int(g[3] ?? ""),
               let hh = Int(g[4] ?? ""), let mm = Int(g[5] ?? "") {
                ts = cal.date(from: DateComponents(year: y, month: mon, day: day, hour: hh, minute: mm))
                    .map { Int($0.timeIntervalSince1970) }
            }
            rows.append(Submission(oj: "projecteuler", id: pid, user: handle, problemId: pid, problemTitle: title,
                                   contestId: nil, verdict: "AC", rawVerdict: diff, score: level, timeMs: nil,
                                   memoryKb: nil, language: nil, codeLength: nil, submitTime: ts,
                                   url: "https://projecteuler.net/problem=\(pid)", raw: jsonString(["lines": lines])))
        }
        if rows.isEmpty {
            throw ImportError.invalid("No solved problems found — open projecteuler.net/progress while signed in, then use the userscript button there.")
        }
        try db.upsert(rows)
        try db.setRatings(rows.map { ("projecteuler", $0.problemId, "pe", $0.score) })
        return rows.count
    }
}
