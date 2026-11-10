// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Foundation

/// Imports data the userscript read from a page the user opened in their own browser.
/// No network access is involved for these platforms.
enum PageImport {
    /// Returns a short human readable summary of what was imported.
    static func run(_ db: Database, oj: String, data: [String: Any]) throws -> String {
        switch Platform(rawValue: oj) {
        case .projecteuler:
            guard let html = data["html"] as? String else { throw ImportError.invalid("The Project Euler payload has no page content.") }
            let n = try ProjectEulerSync.importPage(db, html: html, handle: data["handle"] as? String,
                                                    utcOffsetHours: SettingsStore.shared.settings.projectEulerUTCOffsetHours)
            return "\(n) solved Project Euler problems"
        case .luogu:
            return try LuoguImport.importPage(db, data).summary
        default:
            throw ImportError.invalid("Page import is not supported for \(oj).")
        }
    }
}
