// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// Luogu (luogu.com.cn) is imported from pages you open yourself — SolveLog never contacts Luogu.
///
/// Luogu runs an automatic ban system for automated access and explicitly warns against handing
/// cookies to third-party tools (https://www.luogu.com/discuss/1337298). So instead of signing in,
/// the userscript reads the data that is already embedded in the page you opened
/// (`<script id="lentille-context">`) and puts it on the clipboard:
///
/// * practice page (`/user/<uid>/practice`): every solved problem with its official difficulty — the
///   chart matches the page's 难易度统计 exactly — plus the problems you tried but have not solved.
/// * record list (`/record/list?user=<uid>&page=N`): the 20 submissions shown on that page, wrong
///   answers included. Opening page 1 now and then keeps recent submissions up to date.
enum LuoguImport {
    static let status: [Int: String] = [-1: "UNSHOWN", 0: "PENDING", 1: "JUDGING", 2: "CE", 3: "OLE", 4: "MLE",
                                        5: "TLE", 6: "WA", 7: "RE", 11: "UKE", 12: "AC", 14: "UNAC",
                                        21: "HACK_OK", 22: "HACK_FAIL", 23: "HACK_SKIP"]
    // Luogu's language ids (from its public site config)
    static let languages: [Int: String] = [1: "Pascal", 2: "C", 3: "C++98", 4: "C++11", 5: "Output only",
        6: "Python 2", 7: "Python 3", 8: "Java 8", 9: "Node.js", 10: "Shell", 11: "C++14", 12: "C++17",
        13: "Ruby", 14: "Go", 15: "Rust", 16: "PHP", 17: "C# Mono", 18: "Visual Basic Mono", 19: "Haskell",
        20: "Kotlin/Native", 21: "Kotlin/JVM", 22: "Scala", 23: "Perl", 24: "PyPy 2", 25: "PyPy 3", 26: "文言",
        27: "C++20", 28: "C++14 (GCC 9)", 29: "F#", 30: "OCaml", 31: "Julia", 32: "Lua", 33: "Java 21", 34: "C++23"]

    /// Dispatches on the payload kind. Returns a human readable summary.
    static func importPage(_ db: Database, _ data: [String: Any]) throws -> (count: Int, summary: String) {
        if data["records"] != nil { return try importRecords(db, data) }
        return try importPractice(db, data)
    }

    /// payload: {"oj":"luogu","kind":"practice","uid":1,"passed":[{pid,name,difficulty,type}],"submitted":[…]}
    static func importPractice(_ db: Database, _ data: [String: Any]) throws -> (count: Int, summary: String) {
        guard let passed = data["passed"] as? [[String: Any]] else {
            throw ImportError.invalid("No solved-problem list in the Luogu payload — open your Luogu practice page and use the userscript button there.")
        }
        func problems(_ list: [[String: Any]]) -> [(pid: String, name: String?, difficulty: Double?)] {
            list.compactMap { p in
                guard let pid = p["pid"] as? String, !pid.isEmpty, pid.count < 40 else { return nil }
                return (pid, p["name"] as? String, (p["difficulty"] as? NSNumber)?.doubleValue)
            }
        }
        let solved = problems(passed)
        let tried = problems(data["submitted"] as? [[String: Any]] ?? [])
        if solved.isEmpty && !passed.isEmpty { throw ImportError.invalid("The Luogu payload looks malformed.") }

        // The practice page is authoritative for "solved" and "tried": replace the previous import.
        try db.run("DELETE FROM official_solved WHERE oj='luogu'")
        try db.run("DELETE FROM official_attempted WHERE oj='luogu'")
        try db.run("DELETE FROM submissions WHERE oj='luogu' AND id LIKE 'solved-%'")   // placeholders from v1.0
        try db.run("INSERT OR REPLACE INTO official_solved VALUES ('luogu', ?, ?)", solved.map { [$0.pid, $0.name] })
        try db.run("INSERT OR REPLACE INTO official_attempted VALUES ('luogu', ?, ?)", tried.map { [$0.pid, $0.name] })
        try db.setRatings((solved + tried).map { ("luogu", $0.pid, "luogu", $0.difficulty) })
        return (solved.count, "\(solved.count) solved and \(tried.count) tried-but-unsolved Luogu problems")
    }

    /// payload: {"oj":"luogu","kind":"records","uid":1,"page":1,"records":[{id,status,score,time,memory,…}]}
    static func importRecords(_ db: Database, _ data: [String: Any]) throws -> (count: Int, summary: String) {
        guard let records = data["records"] as? [[String: Any]] else { throw ImportError.invalid("The Luogu payload has no records.") }
        let uid = data["uid"].map { "\($0)" }
        var rows: [Submission] = [], ratings: [(String, String?, String, Double?)] = []
        for x in records {
            guard let idNum = x["id"] as? NSNumber else { continue }
            let sid = idNum.stringValue
            let p = x["problem"] as? [String: Any] ?? [:]
            let st = (x["status"] as? NSNumber)?.intValue ?? -99
            let lang = (x["language"] as? NSNumber)?.intValue
            rows.append(Submission(
                oj: "luogu", id: sid, user: uid, problemId: p["pid"] as? String, problemTitle: p["name"] as? String,
                contestId: ((x["contest"] as? [String: Any])?["id"]).map { "\($0)" },
                verdict: status[st] ?? "\(st)", rawVerdict: "\(st)", score: (x["score"] as? NSNumber)?.doubleValue,
                timeMs: (x["time"] as? NSNumber)?.intValue, memoryKb: (x["memory"] as? NSNumber)?.intValue,
                language: lang.map { languages[$0] ?? "\($0)" }, codeLength: (x["sourceCodeLength"] as? NSNumber)?.intValue,
                submitTime: (x["submitTime"] as? NSNumber)?.intValue, url: "https://www.luogu.com.cn/record/\(sid)",
                raw: jsonString(x)))
            ratings.append(("luogu", p["pid"] as? String, "luogu", (p["difficulty"] as? NSNumber)?.doubleValue))
        }
        if rows.isEmpty { throw ImportError.invalid("No submissions found in the Luogu payload.") }
        try db.upsert(rows)
        try db.setRatings(ratings, overwrite: false)   // the practice page stays authoritative
        let page = (data["page"] as? NSNumber)?.intValue ?? 1
        let stored = db.scalarInt("SELECT COUNT(*) FROM submissions WHERE oj='luogu'") ?? rows.count
        return (rows.count, "\(rows.count) Luogu submissions from record page \(page) (\(stored) stored in total)")
    }
}
