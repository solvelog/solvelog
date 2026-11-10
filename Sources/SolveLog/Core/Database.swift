// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation
import SQLite3

/// One stored submission. `verdict` is normalised across judges (AC, WA, TLE, MLE, RE, CE, PARTIAL, ...).
struct Submission {
    var oj: String
    var id: String
    var user: String?
    var problemId: String?
    var problemTitle: String?
    var contestId: String?
    var verdict: String?
    var rawVerdict: String?
    var score: Double?
    var timeMs: Int?
    var memoryKb: Int?
    var language: String?
    var codeLength: Int?
    var submitTime: Int?
    var url: String?
    var raw: String?

    static let columns = ["oj", "id", "user", "problem_id", "problem_title", "contest_id", "verdict",
                          "raw_verdict", "score", "time_ms", "memory_kb", "language", "code_length",
                          "submit_time", "url", "raw"]

    var values: [Any?] {
        [oj, id, user, problemId, problemTitle, contestId, verdict, rawVerdict, score, timeMs, memoryKb,
         language, codeLength, submitTime, url, raw]
    }

    var isFinal: Bool { !(verdict == nil || verdict == "PENDING" || verdict == "JUDGING") }
}

enum DBError: Error, LocalizedError {
    case sqlite(String)
    var errorDescription: String? { if case .sqlite(let m) = self { return "Database error: \(m)" }; return nil }
}

/// A small thread-safe SQLite wrapper. All access goes through one serialised connection.
final class Database {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    let url: URL

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let schema = """
    CREATE TABLE IF NOT EXISTS submissions (
        oj TEXT NOT NULL, id TEXT NOT NULL, user TEXT, problem_id TEXT, problem_title TEXT,
        contest_id TEXT, verdict TEXT, raw_verdict TEXT, score REAL, time_ms INTEGER,
        memory_kb INTEGER, language TEXT, code_length INTEGER, submit_time INTEGER, url TEXT, raw TEXT,
        PRIMARY KEY (oj, id));
    CREATE INDEX IF NOT EXISTS idx_time ON submissions(oj, submit_time);
    CREATE TABLE IF NOT EXISTS problem_ratings (
        oj TEXT NOT NULL, problem_id TEXT NOT NULL, source TEXT NOT NULL, rating REAL NOT NULL,
        PRIMARY KEY (oj, problem_id, source));
    CREATE TABLE IF NOT EXISTS official_solved (
        oj TEXT NOT NULL, problem_id TEXT NOT NULL, title TEXT, PRIMARY KEY (oj, problem_id));
    CREATE TABLE IF NOT EXISTS official_attempted (
        oj TEXT NOT NULL, problem_id TEXT NOT NULL, title TEXT, PRIMARY KEY (oj, problem_id));
    CREATE TABLE IF NOT EXISTS sync_state (
        oj TEXT NOT NULL, account TEXT NOT NULL, complete INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (oj, account));
    """

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw DBError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 10_000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec(Database.schema)
    }

    deinit { sqlite3_close(db) }

    // MARK: - low level

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.sqlite(msg)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [Any?]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, idx)
            case let x as Int: sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as Int64: sqlite3_bind_int64(stmt, idx, x)
            case let x as Double: sqlite3_bind_double(stmt, idx, x)
            case let x as Bool: sqlite3_bind_int64(stmt, idx, x ? 1 : 0)
            case let x as String: sqlite3_bind_text(stmt, idx, x, -1, Database.transient)
            default: sqlite3_bind_text(stmt, idx, "\(v!)", -1, Database.transient)
            }
        }
    }

    private func column(_ stmt: OpaquePointer?, _ i: Int32) -> Any? {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return Int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return sqlite3_column_double(stmt, i)
        case SQLITE_TEXT: return String(cString: sqlite3_column_text(stmt, i))
        default: return nil
        }
    }

    /// Runs a statement once per parameter row inside a single transaction.
    func run(_ sql: String, _ rows: [[Any?]]) throws {
        guard !rows.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bind(stmt, row)
            if sqlite3_step(stmt) != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw DBError.sqlite(msg)
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func run(_ sql: String, _ params: Any?...) throws { try run(sql, [params]) }

    func query(_ sql: String, _ params: [Any?] = []) throws -> [[Any?]] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        var out: [[Any?]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<n).map { column(stmt, $0) })
        }
        return out
    }

    // MARK: - submissions

    func upsert(_ subs: [Submission]) throws {
        let sql = "INSERT OR REPLACE INTO submissions (\(Submission.columns.joined(separator: ","))) VALUES (\(Array(repeating: "?", count: Submission.columns.count).joined(separator: ",")))"
        try run(sql, subs.map { $0.values })
    }

    /// Ids that already have a final verdict. Incremental syncs stop when they reach one of these.
    func knownFinalIds(_ oj: String) throws -> Set<String> {
        Set(try query("SELECT id FROM submissions WHERE oj=? AND verdict NOT IN ('PENDING','JUDGING')", [oj])
            .compactMap { $0[0] as? String })
    }

    func historyComplete(_ oj: String, _ account: String) -> Bool {
        ((try? query("SELECT complete FROM sync_state WHERE oj=? AND account=?", [oj, account]))?.first?[0] as? Int) == 1
    }

    func markComplete(_ oj: String, _ account: String) throws {
        try run("INSERT OR REPLACE INTO sync_state (oj, account, complete) VALUES (?, ?, 1)", oj, account)
    }

    /// rows: (oj, problem id, source, rating). Rows with a nil id or rating are skipped.
    func setRatings(_ rows: [(String, String?, String, Double?)], overwrite: Bool = true) throws {
        let clean = rows.compactMap { r -> [Any?]? in
            guard let p = r.1, let v = r.3 else { return nil }
            return [r.0, p, r.2, v]
        }
        try run("INSERT OR \(overwrite ? "REPLACE" : "IGNORE") INTO problem_ratings VALUES (?,?,?,?)", clean)
    }

    func scalarInt(_ sql: String, _ params: [Any?] = []) -> Int? {
        (try? query(sql, params))?.first?.first.flatMap { $0 as? Int }
    }

    func deleteAll() throws {
        try exec("DELETE FROM submissions; DELETE FROM problem_ratings; DELETE FROM official_solved; DELETE FROM official_attempted; DELETE FROM sync_state;")
    }
}
