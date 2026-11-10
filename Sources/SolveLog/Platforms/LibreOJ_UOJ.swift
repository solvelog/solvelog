// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// LibreOJ public API (no login).
enum LibreOJSync {
    static let status = ["Accepted": "AC", "WrongAnswer": "WA", "TimeLimitExceeded": "TLE",
        "MemoryLimitExceeded": "MLE", "RuntimeError": "RE", "CompilationError": "CE", "OutputLimitExceeded": "OLE",
        "PartiallyCorrect": "PARTIAL", "Pending": "PENDING", "Waiting": "PENDING", "Compiling": "JUDGING",
        "Running": "JUDGING", "Judging": "JUDGING", "SystemError": "UKE", "JudgementFailed": "UKE",
        "ConfigurationError": "UKE", "FileError": "RE", "InvalidInteraction": "WA", "Canceled": "CANCELED"]

    static func run(_ db: Database, handles: [String], full: Bool) async throws -> Int {
        let known = full ? [] : try db.knownFinalIds("loj")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var total = 0
        for handle in handles {
            let stop = db.historyComplete("loj", handle) ? known : []
            var maxId: Int?, n = 0
            while true {
                var body: [String: Any] = ["locale": "en_US", "submitter": handle, "takeCount": 50]
                if let m = maxId { body["maxId"] = m }
                let obj = try await HTTP.json(URL(string: "https://api.loj.ac/api/submission/querySubmission")!,
                                              method: "POST", headers: ["Content-Type": "application/json"],
                                              body: try JSONSerialization.data(withJSONObject: body))
                guard let d = obj as? [String: Any] else { throw HTTPError.badResponse("LibreOJ: unexpected response") }
                if let err = d["error"] as? String { throw HTTPError.badResponse("LibreOJ: \(err) (\(handle))") }
                let subs = d["submissions"] as? [[String: Any]] ?? []
                let rows: [Submission] = subs.map { x0 in
                    var x = x0
                    x.removeValue(forKey: "submitter")   // contains the account e-mail; never store it
                    let prob = x["problem"] as? [String: Any] ?? [:]
                    let st = x["status"] as? String
                    return Submission(
                        oj: "loj", id: "\(x["id"] ?? "")", user: handle,
                        problemId: "\(prob["displayId"] ?? prob["id"] ?? "")", problemTitle: x["problemTitle"] as? String,
                        contestId: nil, verdict: st.map { status[$0] ?? $0 }, rawVerdict: st,
                        score: (x["score"] as? NSNumber)?.doubleValue, timeMs: x["timeUsed"] as? Int,
                        memoryKb: x["memoryUsed"] as? Int, language: x["codeLanguage"] as? String,
                        codeLength: x["answerSize"] as? Int,
                        submitTime: (x["submitTime"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                            .map { Int($0.timeIntervalSince1970) },
                        url: "https://loj.ac/s/\(x["id"] ?? "")", raw: jsonString(x))
                }
                try db.upsert(rows)
                n += rows.count
                if subs.isEmpty || !(d["hasSmallerId"] as? Bool ?? false) {
                    try db.markComplete("loj", handle)
                    break
                }
                if rows.contains(where: { stop.contains($0.id) }) { break }
                maxId = (subs.compactMap { $0["id"] as? Int }.min() ?? 1) - 1
                try await HTTP.pause(1.5)
            }
            SyncLog.shared.write("  \(handle): \(n) submissions")
            total += n
        }
        return total
    }
}

/// UOJ (uoj.ac). Submission lists need any signed-in cookie; that one cookie can read every handle.
enum UOJSync {
    // UOJ watches for automated access, so: random 4–9 s pauses, at most once per 30 minutes, at most
    // 10 pages per sync *in total* (every handle is read through the same signed-in account), stop and
    // back off for 6 hours on any limit, no retries, never part of automatic syncs.
    struct State: Codable { var lastSync = 0.0, cooldownUntil = 0.0, resume: [String: Int] = [:] }
    static let minGap = 30.0 * 60, maxPages = 10, cooldown = 6.0 * 3600
    static func politePause() async throws { try await HTTP.pause(Double.random(in: 4...9)) }
    static var stateURL: URL { SettingsStore.shared.directory.appendingPathComponent("uoj_state.json") }

    static func run(_ db: Database, handles: [String], cookie: String, full: Bool) async throws -> Int {
        var st = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
        func save() { if let d = try? JSONEncoder().encode(st) { try? d.write(to: stateURL, options: .atomic) } }
        let now = Date().timeIntervalSince1970
        if now < st.cooldownUntil {
            throw HTTPError.badResponse("UOJ is paused until \(DateFormatter.localizedString(from: Date(timeIntervalSince1970: st.cooldownUntil), dateStyle: .none, timeStyle: .short)) after a rate-limit response")
        }
        if now - st.lastSync < minGap && !full {
            SyncLog.shared.write("  skipped: last UOJ sync was \(Int((now - st.lastSync) / 60)) min ago (minimum gap 30 min)")
            return 0
        }
        st.lastSync = now; save()

        let known = full ? [] : try db.knownFinalIds("uoj")
        let session = HTTP.cookieSession(cookie, domain: "uoj.ac")
        var total = 0, budget = maxPages, first = true
        for handle in handles {
            if budget <= 0 { SyncLog.shared.write("  page budget used up — \(handle) and later accounts continue next sync"); break }
            let complete = db.historyComplete("uoj", handle) && !full
            let stop = complete ? known : []
            var page = complete || full ? 1 : max(1, st.resume[handle] ?? 1), n = 0
            while true {
                if !first { try await politePause() }
                first = false
                let html: String
                do {
                    (html, _) = try await HTTP.text(HTTP.url("https://uoj.ac/submissions", ["submitter": handle, "page": page]),
                                                    session: session, retries: 1)
                } catch {
                    st.cooldownUntil = Date().timeIntervalSince1970 + cooldown; save()
                    throw HTTPError.badResponse("UOJ limited the request (\(error.localizedDescription)) — stopped; UOJ is paused for 6 hours")
                }
                if html.contains("<title>登录") || html.contains("<title>Log in") {
                    save()
                    throw HTTPError.notSignedIn("UOJ needs a signed-in cookie — it has expired, import it again")
                }
                let rows = parse(html, handle: handle)
                try db.upsert(rows)
                n += rows.count
                budget -= 1
                if rows.isEmpty || !hasNextPage(html) {
                    try db.markComplete("uoj", handle)
                    st.resume[handle] = 1
                    break
                }
                if complete && rows.contains(where: { stop.contains($0.id) }) { break }
                if budget <= 0 {
                    if !complete {
                        st.resume[handle] = page + 1
                        SyncLog.shared.write("  \(handle): history not finished — continuing from page \(page + 1) next sync")
                    }
                    break
                }
                page += 1
            }
            SyncLog.shared.write("  \(handle): \(n) submissions")
            total += n
        }
        save()
        return total
    }

    static func hasNextPage(_ html: String) -> Bool {
        guard let ul = html.firstMatch(#"<ul class="pagination[^"]*">(.*?)</ul>"#) else { return false }
        let lis = ul.matches(#"<li([^>]*)>"#).compactMap { $0[1] }
        return !(lis.last?.contains("disabled") ?? true)
    }

    static func parse(_ html: String, handle: String) -> [Submission] {
        let cst = TimeZone(secondsFromGMT: 8 * 3600)!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = cst; fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var rows: [Submission] = []
        for m in html.matches(#"<tr>(.*?)</tr>"#) {
            guard let tr = m[1] else { continue }
            let tds = tr.matches(#"<td[^>]*>(.*?)</td>"#).compactMap { $0[1] }
            guard tds.count >= 9, let sid = tds[0].firstMatch(#"/submission/(\d+)"#) else { continue }
            let text = tds.map { $0.strippingTags.trimmed }
            let result = text[3]
            var verdict: String?, score: Double?
            if let v = Double(result) {
                score = v; verdict = v >= 100 ? "AC" : v > 0 ? "PARTIAL" : "WA"
            } else {
                let low = result.lowercased()
                verdict = [("compile", "CE"), ("judgement failed", "UKE"), ("waiting", "PENDING"), ("judging", "JUDGING"),
                           ("compiling", "JUDGING"), ("编译", "CE"), ("等待", "PENDING"), ("评测中", "JUDGING")]
                    .first { low.contains($0.0) }?.1 ?? (result.isEmpty ? nil : result)
            }
            let size = text[7].lowercased()
            let sizeBytes = size.leadingNumber.map { Int($0 * (size.contains("mb") ? 1048576 : size.contains("kb") ? 1024 : 1)) }
            rows.append(Submission(
                oj: "uoj", id: sid, user: handle, problemId: tds[1].firstMatch(#"/problem/(\d+)"#),
                problemTitle: text[1].replacingOccurrences(of: #"^#\d+\.\s*"#, with: "", options: .regularExpression),
                contestId: nil, verdict: verdict, rawVerdict: result, score: score,
                timeMs: text[4].leadingNumber.map { Int($0) }, memoryKb: text[5].leadingNumber.map { Int($0) },
                language: text[6].isEmpty ? nil : text[6], codeLength: sizeBytes,
                submitTime: fmt.date(from: String(text[8].prefix(19))).map { Int($0.timeIntervalSince1970) },
                url: "https://uoj.ac/submission/\(sid)", raw: jsonString(["cells": text])))
        }
        return rows
    }
}
