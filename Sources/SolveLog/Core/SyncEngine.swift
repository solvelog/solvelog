// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

struct SyncResult {
    var ok: Bool
    var log: String
    var failed: [Platform]
}

/// Runs every configured platform. Different judges are fetched in parallel (each one still
/// spaces out its own requests); one platform failing never stops the others.
final class SyncEngine {
    let db: Database
    private(set) var running = false
    init(db: Database) { self.db = db }

    /// `automatic` (e.g. sync on launch) leaves out UOJ, which is only contacted when you click Sync.
    /// Luogu and Project Euler are never fetched: they are imported from pages the user opens.
    func sync(only: [Platform]? = nil, full: Bool = false, automatic: Bool = false) async -> SyncResult {
        guard !running else { return SyncResult(ok: false, log: "A sync is already running.", failed: []) }
        running = true
        defer { running = false }
        SyncLog.shared.reset()
        let store = SettingsStore.shared
        let settings = store.settings
        let targets = (only ?? store.configuredPlatforms()).filter { !$0.pageImport && !(automatic && $0 == .uoj) }
        if targets.isEmpty {
            return SyncResult(ok: false, log: "Nothing to sync yet — open Settings (⌘,) and add your accounts.", failed: [])
        }

        var failed: [Platform] = []
        let runOne: (Platform) async -> Platform? = { p in
            SyncLog.shared.write("[\(p.name)] syncing…")
            do {
                let n = try await self.syncPlatform(p, settings: settings, full: full)
                SyncLog.shared.write("[\(p.name)] done, \(n) records processed")
                return nil
            } catch {
                SyncLog.shared.write("[\(p.name)] failed: \(error.localizedDescription)")
                return p
            }
        }
        if settings.parallelSync {
            await withTaskGroup(of: Platform?.self) { group in
                for p in targets { group.addTask { await runOne(p) } }
                for await r in group { if let p = r { failed.append(p) } }
            }
        } else {
            for p in targets { if let f = await runOne(p) { failed.append(f) } }
        }

        await Ratings.refreshMissing(db)
        do { try await Ratings.clist(db) } catch { SyncLog.shared.write("[clist] failed: \(error.localizedDescription)") }
        return SyncResult(ok: failed.isEmpty, log: SyncLog.shared.text, failed: failed)
    }

    private func syncPlatform(_ p: Platform, settings: AppSettings, full: Bool) async throws -> Int {
        let store = SettingsStore.shared
        let handles = settings.handles(for: p)
        func cookie() throws -> String {
            guard let c = store.cookie(p) else { throw HTTPError.notSignedIn("\(p.name) needs a login cookie — import it in Settings") }
            return c
        }
        switch p {
        case .codeforces: return try await CodeforcesSync.run(db, handles: handles, full: full)
        case .atcoder: return try await AtCoderSync.run(db, handles: handles, full: full)
        case .luogu, .projecteuler: return 0   // imported from pages the user opens; never fetched
        case .codechef: return try await CodeChefSync.run(db, handles: handles, full: full)
        case .loj: return try await LibreOJSync.run(db, handles: handles, full: full)
        case .uoj: return try await UOJSync.run(db, handles: handles, cookie: try cookie(), full: full)
        }
    }
}
