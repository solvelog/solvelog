// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

enum ImportError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let m) = self { return m }; return nil }
}

/// Submission backup (CSV / JSON) and settings transfer. Secrets are never exported.
enum ImportExport {
    static let exportColumns = Submission.columns.filter { $0 != "raw" }

    // MARK: submissions

    static func exportSubmissions(_ db: Database, to url: URL) throws -> Int {
        let rows = try db.query("SELECT \(exportColumns.joined(separator: ",")) FROM submissions ORDER BY submit_time")
        if url.pathExtension.lowercased() == "json" {
            let objs: [[String: Any]] = rows.map { r in
                var d: [String: Any] = [:]
                for (k, v) in zip(exportColumns, r) { d[k] = v ?? NSNull() }
                return d
            }
            let data = try JSONSerialization.data(withJSONObject: ["format": "solvelog-submissions", "version": 1, "submissions": objs],
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } else {
            var out = exportColumns.joined(separator: ",") + "\n"
            for r in rows { out += r.map { csvField($0) }.joined(separator: ",") + "\n" }
            try out.write(to: url, atomically: true, encoding: .utf8)
        }
        return rows.count
    }

    static func importSubmissions(_ db: Database, from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        var records: [[String: Any]]
        if url.pathExtension.lowercased() == "json" {
            let obj = try JSONSerialization.jsonObject(with: data)
            if let d = obj as? [String: Any], let s = d["submissions"] as? [[String: Any]] { records = s }
            else if let a = obj as? [[String: Any]] { records = a }
            else { throw ImportError.invalid("This JSON file is not a SolveLog submission export.") }
        } else {
            let table = parseCSV(String(decoding: data, as: UTF8.self))
            guard let header = table.first, header.contains("oj"), header.contains("id") else {
                throw ImportError.invalid("The CSV needs at least the columns \"oj\" and \"id\" (use a SolveLog export).")
            }
            records = table.dropFirst().filter { $0.count == header.count }.map { Dictionary(uniqueKeysWithValues: zip(header, $0.map { $0 as Any })) }
        }
        let known = Set(Platform.allCases.map { $0.rawValue })
        let subs: [Submission] = records.compactMap { r in
            func s(_ k: String) -> String? { let v = r[k]; if v is NSNull { return nil }; let t = v.map { "\($0)" }; return (t?.isEmpty ?? true) ? nil : t }
            func i(_ k: String) -> Int? { s(k).flatMap { Int($0) ?? Double($0).map { Int($0) } } }
            guard let oj = s("oj"), known.contains(oj), let id = s("id") else { return nil }
            return Submission(oj: oj, id: id, user: s("user"), problemId: s("problem_id"), problemTitle: s("problem_title"),
                              contestId: s("contest_id"), verdict: s("verdict"), rawVerdict: s("raw_verdict"),
                              score: s("score").flatMap(Double.init), timeMs: i("time_ms"), memoryKb: i("memory_kb"),
                              language: s("language"), codeLength: i("code_length"), submitTime: i("submit_time"),
                              url: s("url"), raw: nil)
        }
        if subs.isEmpty { throw ImportError.invalid("No usable submissions found in this file.") }
        try db.upsert(subs)
        return subs.count
    }

    static func csvField(_ v: Any?) -> String {
        guard let v = v else { return "" }
        let s = "\(v)"
        if s.contains(",") || s.contains("\"") || s.contains("\n") { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return s
    }

    /// RFC-4180 style CSV parser (quoted fields, escaped quotes, embedded newlines).
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", inQuotes = false
        var it = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n } }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: settings (no secrets)

    static func exportSettings(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let s = try JSONSerialization.jsonObject(with: try enc.encode(SettingsStore.shared.settings))
        let wrapper: [String: Any] = ["format": "solvelog-settings", "version": 1, "settings": s,
                                      "note": "Cookies and API keys are not included. Import them again on the new machine."]
        try JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    static func importSettings(from url: URL) throws {
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let d = obj as? [String: Any], d["format"] as? String == "solvelog-settings", let s = d["settings"] else {
            throw ImportError.invalid("This file is not a SolveLog settings export.")
        }
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: s))
        SettingsStore.shared.settings = settings
    }
}

/// What the SolveLog userscript puts on the clipboard:
///   `solvelog-cookie:{"v":1,"oj":"uoj","cookie":"a=b; c=d"}`                (UOJ)
///   `solvelog-page:{"v":1,"oj":"projecteuler","html":"…","handle":"…"}`     (the Project Euler progress page you opened)
///   `solvelog-page:{"v":1,"oj":"luogu","kind":"practice","uid":1,"passed":[…],"submitted":[…]}` (Luogu practice page)
///   `solvelog-page:{"v":1,"oj":"luogu","kind":"records","uid":1,"page":1,"records":[…]}`       (Luogu record list page)
enum ClipboardPayload {
    case cookie(String)
    case page(oj: String, data: [String: Any])

    static func parse(_ text: String) throws -> ClipboardPayload {
        var t = text.trimmed
        for prefix in [CookieImport.prefix, "solvelog-page:"] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any], let oj = obj["oj"] as? String else {
            throw ImportError.invalid("That is not something the SolveLog userscript copied.")
        }
        if obj["html"] != nil || obj["passed"] != nil || obj["records"] != nil {
            guard Platform(rawValue: oj)?.pageImport == true else { throw ImportError.invalid("Page import is not supported for \(oj).") }
            return .page(oj: oj, data: obj)
        }
        return .cookie(t)
    }
}

enum CookieImport {
    static let prefix = "solvelog-cookie:"

    /// Validates and stores the cookie in the Keychain. Returns the platform it belongs to.
    static func importPayload(_ text: String) throws -> Platform {
        var t = text.trimmed
        if t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
              let ojs = obj["oj"] as? String, let cookie = obj["cookie"] as? String else {
            throw ImportError.invalid("That is not a SolveLog cookie. Use the “Copy to SolveLog” button of the userscript.")
        }
        guard let p = Platform(rawValue: ojs), p.needsCookie else { throw ImportError.invalid("Unsupported platform: \(ojs)") }
        guard !cookie.isEmpty, cookie.count < 8000, !cookie.contains("\n"), !cookie.contains("\r") else {
            throw ImportError.invalid("The cookie looks malformed.")
        }
        let jar = parseCookieString(cookie)
        switch p {
        case .uoj:
            guard jar["UOJSESSID"] != nil || jar["uoj_remember_token"] != nil else {
                throw ImportError.invalid("The UOJ cookie has no session — are you signed in?")
            }
        default: break
        }
        guard Keychain.set(SettingsStore.shared.cookieKey(p), cookie) else {
            throw ImportError.invalid("Could not save the cookie to the Keychain.")
        }
        return p
    }

    static func describe(_ p: Platform) -> String {
        guard let c = SettingsStore.shared.cookie(p) else { return "Not set" }
        let jar = parseCookieString(c)
        if p == .uoj, let u = jar["uoj_username"] { return "Saved (signed in as \(u))" }
        return "Saved"
    }
}
