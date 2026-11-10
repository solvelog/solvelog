// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

enum HTTPError: Error, LocalizedError {
    case status(Int, String)
    case notSignedIn(String)
    case badResponse(String)
    case rateLimited(String)

    var errorDescription: String? {
        switch self {
        case .status(let c, let u): return "HTTP \(c) from \(u)"
        case .notSignedIn(let m): return m
        case .badResponse(let m): return m
        case .rateLimited(let u): return "Still rate limited after several retries: \(u)"
        }
    }
}

/// Polite HTTP client: browser-like UA, no shared cookie jar, retries with backoff,
/// honours HTTP 429 / Retry-After. Every judge is fetched slowly on purpose.
enum HTTP {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 SolveLog/1.0"

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 45
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// A private, in-memory session preloaded with a site's sign-in cookies. It also keeps cookies the
    /// site sets during the sync (Luogu answers the first request with a 302 + a short-lived cookie).
    /// Nothing is written to the shared cookie store, and the session is thrown away after the sync.
    static func cookieSession(_ cookie: String, domain: String) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        c.timeoutIntervalForRequest = 45
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        let store = c.httpCookieStorage ?? HTTPCookieStorage()
        for (name, value) in parseCookieString(cookie) {
            if let k = HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: value, .secure: "TRUE"]) {
                store.setCookie(k)
            }
        }
        c.httpCookieStorage = store
        return URLSession(configuration: c)
    }

    static func url(_ base: String, _ query: [String: Any] = [:]) -> URL {
        var comps = URLComponents(string: base)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        }
        return comps.url!
    }

    /// Fetches `url`. Returns body + final response. Follows no redirects when `followRedirects` is false.
    static func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                      retries: Int = 4, session: URLSession? = nil) async throws -> (Data, HTTPURLResponse) {
        let session = session ?? HTTP.session
        var lastError: Error = HTTPError.badResponse("no response")
        for attempt in 0..<retries {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw HTTPError.badResponse("not HTTP") }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw HTTPError.status(http.statusCode, url.host ?? "")
                }
                if http.statusCode == 429 {
                    let ra = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(60 * (attempt + 1))
                    if attempt == retries - 1 { throw HTTPError.rateLimited(url.host ?? "") }
                    SyncLog.shared.write("  rate limited by \(url.host ?? ""), waiting \(Int(ra))s")
                    try await Task.sleep(nanoseconds: UInt64(ra * 1e9))
                    continue
                }
                lastError = HTTPError.status(http.statusCode, url.host ?? "")
            } catch let e as HTTPError {
                if case .status(let c, _) = e, c == 401 || c == 403 { throw e }
                if case .rateLimited = e { throw e }
                lastError = e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 2e9))
        }
        throw lastError
    }

    static func json(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                     session: URLSession? = nil) async throws -> Any {
        let (data, _) = try await fetch(url, method: method, headers: headers, body: body, session: session)
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw HTTPError.badResponse("Expected JSON from \(url.host ?? "")") }
    }

    static func text(_ url: URL, headers: [String: String] = [:], session: URLSession? = nil, retries: Int = 4) async throws -> (String, HTTPURLResponse) {
        let (data, resp) = try await fetch(url, headers: headers, retries: retries, session: session)
        return (String(decoding: data, as: UTF8.self), resp)
    }

    static func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }
}

/// Collects human-readable sync progress for the log panel.
final class SyncLog {
    static let shared = SyncLog()
    private var lines: [String] = []
    private let lock = NSLock()
    func reset() { lock.lock(); lines = []; lock.unlock() }
    func write(_ s: String) { lock.lock(); lines.append(s); lock.unlock(); NSLog("%@", s) }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

// MARK: - small parsing helpers shared by the HTML scrapers

extension String {
    func matches(_ pattern: String, options: NSRegularExpression.Options = [.dotMatchesLineSeparators]) -> [[String?]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    func firstMatch(_ pattern: String, group: Int = 1) -> String? {
        matches(pattern).first.flatMap { $0.count > group ? $0[group] : nil }
    }

    var strippingTags: String {
        var s = replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " ", "&#039;": "'"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// First run of digits as Int, e.g. "1512ms" → 1512.
    var leadingNumber: Double? { firstMatch(#"(\d+(?:\.\d+)?)"#).flatMap(Double.init) }
}

func parseCookieString(_ cookie: String) -> [String: String] {
    var out: [String: String] = [:]
    for part in cookie.split(separator: ";") {
        let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmed }
        if kv.count == 2 { out[kv[0]] = kv[1] }
    }
    return out
}

func jsonString(_ obj: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(obj),
          let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
    return String(data: d, encoding: .utf8)
}
