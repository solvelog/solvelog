// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation
import Security

/// Platforms SolveLog knows about. `id` is what ends up in the database's `oj` column.
enum Platform: String, CaseIterable, Codable, Identifiable {
    case codeforces, atcoder, luogu, projecteuler, codechef, loj, uoj
    var id: String { rawValue }

    var name: String {
        switch self {
        case .codeforces: return "Codeforces"
        case .atcoder: return "AtCoder"
        case .luogu: return "Luogu"
        case .projecteuler: return "Project Euler"
        case .codechef: return "CodeChef"
        case .loj: return "LibreOJ"
        case .uoj: return "UOJ"
        }
    }

    /// Platforms whose data is only visible when signed in. Their cookie comes from the browser userscript.
    var needsCookie: Bool { self == .uoj }

    /// Platforms imported from a page you open yourself (no requests by SolveLog at all).
    var pageImport: Bool { self == .projecteuler || self == .luogu }

    /// Platforms without a handle list (account comes from the cookie or the imported page).
    var accountFromCookie: Bool { self == .luogu || self == .projecteuler }

    var handleHint: String {
        switch self {
        case .uoj: return "UOJ handles to track (any signed-in cookie can read all of them)"
        case .luogu: return "Luogu is imported from your practice page"
        case .projecteuler: return "Project Euler is imported from your Progress page"
        default: return "Handles, comma separated — several accounts are merged into one total"
        }
    }
}

/// Non-secret settings, stored as JSON in Application Support. Secrets live in the Keychain.
struct AppSettings: Codable, Equatable {
    var handles: [String: [String]] = [:]          // platform id → handles
    var projectEulerUTCOffsetHours: Double = Double(TimeZone.current.secondsFromGMT()) / 3600
    var clistUsername: String = ""
    var syncOnLaunch: Bool = false
    var parallelSync: Bool = true
    var theme: String = "auto"

    func handles(for p: Platform) -> [String] {
        (handles[p.rawValue] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings { didSet { if settings != oldValue { save() } } }

    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    private init() {
        // SOLVELOG_HOME relocates all data (handy for testing or a portable setup)
        if let home = ProcessInfo.processInfo.environment["SOLVELOG_HOME"], !home.isEmpty {
            directory = URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appendingPathComponent("SolveLog", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Platforms that have enough configuration to sync.
    func configuredPlatforms() -> [Platform] {
        Platform.allCases.filter { p in
            switch p {
            case .luogu, .projecteuler: return false   // page import only — never fetched
            case .uoj: return Keychain.get(cookieKey(p)) != nil && !settings.handles(for: p).isEmpty
            default: return !settings.handles(for: p).isEmpty
            }
        }
    }

    func cookieKey(_ p: Platform) -> String { "cookie.\(p.rawValue)" }
    func cookie(_ p: Platform) -> String? { Keychain.get(cookieKey(p)) }
    var clistAPIKey: String? { Keychain.get("clist.apikey") }
}

/// Minimal wrapper around the login Keychain (generic passwords, service "SolveLog").
enum Keychain {
    static let service = "SolveLog"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(data: d, encoding: .utf8)
        return (s?.isEmpty ?? true) ? nil : s
    }

    @discardableResult
    static func set(_ key: String, _ value: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let v = value, !v.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrLabel as String] = "SolveLog \(key)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
