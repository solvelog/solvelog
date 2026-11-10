// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// Headless mode: `SolveLog --cli <command>`. Useful for scripting (cron, launchd) and testing.
enum CLI {
    static let usage = """
    Usage: SolveLog --cli <command>
      sync [--full] [platform…]      sync configured platforms (or only the given ones)
      stats                          print totals per platform
      handles <platform> <h1,h2…>    set the handles for a platform
      import-cookie                  read a "solvelog-cookie:" payload from stdin into the Keychain
      import-page                    read a "solvelog-page:" payload (Luogu / Project Euler page) from stdin
      export <file.csv|file.json>    export all submissions
      import <file.csv|file.json>    import submissions
      dashboard                      print the dashboard JSON
    Data lives in ~/Library/Application Support/SolveLog (override with SOLVELOG_HOME).
    """

    static func run(_ args: [String]) -> Int32 {
        guard let cmd = args.first else { print(usage); return 2 }
        do {
            let db = try Database(url: SettingsStore.shared.directory.appendingPathComponent("solvelog.db"))
            switch cmd {
            case "sync":
                let full = args.contains("--full")
                let only = args.dropFirst().filter { $0 != "--full" }.compactMap { Platform(rawValue: $0) }
                let sem = DispatchSemaphore(value: 0)
                var result: SyncResult!
                Task { result = await SyncEngine(db: db).sync(only: only.isEmpty ? nil : only, full: full); sem.signal() }
                sem.wait()
                print(result.log)
                return result.ok ? 0 : 1
            case "stats":
                for r in try db.query("""
                    SELECT oj, COUNT(*), SUM(verdict='AC'), COUNT(DISTINCT CASE WHEN verdict='AC' THEN problem_id END)
                    FROM submissions GROUP BY oj ORDER BY oj
                    """) {
                    print(String(format: "%-14@ %7d subs %7d AC %6d solved", (r[0] as? String ?? "") as NSString,
                                 r[1] as? Int ?? 0, r[2] as? Int ?? 0, r[3] as? Int ?? 0))
                }
                return 0
            case "handles":
                guard args.count >= 3, let p = Platform(rawValue: args[1]) else { print(usage); return 2 }
                SettingsStore.shared.settings.handles[p.rawValue] = args[2].split(separator: ",").map { String($0).trimmed }
                return 0
            case "import-cookie":
                let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                print("saved \(try CookieImport.importPayload(input).name) sign-in")
                return 0
            case "import-page":
                let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                guard case .page(let oj, let data) = try ClipboardPayload.parse(input) else {
                    throw ImportError.invalid("stdin is not a solvelog-page: payload")
                }
                print("imported \(try PageImport.run(db, oj: oj, data: data))")
                return 0
            case "export":
                guard args.count >= 2 else { print(usage); return 2 }
                print("exported \(try ImportExport.exportSubmissions(db, to: URL(fileURLWithPath: args[1])))")
                return 0
            case "import":
                guard args.count >= 2 else { print(usage); return 2 }
                print("imported \(try ImportExport.importSubmissions(db, from: URL(fileURLWithPath: args[1])))")
                return 0
            case "dashboard":
                print(String(decoding: try JSONSerialization.data(withJSONObject: try Dashboard.payload(db)), as: UTF8.self))
                return 0
            default:
                print(usage); return 2
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
