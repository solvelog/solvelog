// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    weak var app: AppDelegate?
    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.2") }
            CookiesTab(app: app).tabItem { Label("Sign-in", systemImage: "key") }
            RatingsTab(app: app).tabItem { Label("Ratings", systemImage: "chart.bar") }
            DataTab(app: app).tabItem { Label("Data", systemImage: "externaldrive") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(width: 620, height: 520)
    }
}

// MARK: - Accounts

struct AccountsTab: View {
    @ObservedObject var store = SettingsStore.shared
    @State private var texts: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(Platform.allCases.filter { !$0.accountFromCookie }) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        TextField(p.name, text: Binding(
                            get: { texts[p.rawValue] ?? "" },
                            set: { v in
                                texts[p.rawValue] = v
                                store.settings.handles[p.rawValue] = v.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
                            }), prompt: Text("handle1, handle2"))
                        Text(p.handleHint + (p == .uoj ? " — also import a UOJ cookie under Sign-in." : ""))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            } header: { Text("Your handles") } footer: {
                Text("Luogu and Project Euler are imported from pages you open (Settings → Sign-in), so they have no handle list.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Project Euler") {
                Picker("Account time zone", selection: $store.settings.projectEulerUTCOffsetHours) {
                    ForEach(Array(stride(from: -12.0, through: 14.0, by: 0.5)), id: \.self) { h in
                        Text(String(format: "UTC%@%g", h >= 0 ? "+" : "−", abs(h))).tag(h)
                    }
                }
                Text("Project Euler shows completion times in the time zone set in your PE account.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Syncing") {
                Toggle("Sync when SolveLog opens (UOJ excluded)", isOn: $store.settings.syncOnLaunch)
                Toggle("Fetch different judges in parallel (faster)", isOn: $store.settings.parallelSync)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            for p in Platform.allCases { texts[p.rawValue] = store.settings.handles(for: p).joined(separator: ", ") }
        }
    }
}

// MARK: - Sign-in cookies

struct CookiesTab: View {
    weak var app: AppDelegate?
    @State private var tick = 0
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Text("Luogu and Project Euler need no sign-in in SolveLog. Open the page yourself, click “Send to SolveLog” (from the SolveLog userscript), then press Paste below — or ⌘⇧V anywhere in SolveLog. SolveLog never contacts Luogu or Project Euler on its own.\n• Luogu practice page (profile → 练习): solved and tried problems with difficulty.\n• Luogu record list (评测记录, filtered to you): the 20 submissions on that page — open page 1 now and then for recent submissions.\n• projecteuler.net/progress: solved problems with completion times.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("UOJ only shows submissions when you are signed in: click “Copy to SolveLog” on uoj.ac and paste here.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("UOJ watches for automated access. SolveLog only contacts it when you click Sync (never on launch), at most once every 30 minutes, with random pauses and at most 10 pages per sync; any rate-limit response pauses UOJ for 6 hours. Using a sign-in cookie is still at your own risk.")
                    .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Section("Saved sign-ins") {
                ForEach(Platform.allCases.filter { $0.needsCookie }) { p in
                    HStack {
                        Text(p.name).frame(width: 110, alignment: .leading)
                        Text(CookieImport.describe(p)).foregroundColor(SettingsStore.shared.cookie(p) == nil ? .secondary : .primary)
                            .id(tick)
                        Spacer()
                        Button("Remove") { Keychain.set(SettingsStore.shared.cookieKey(p), nil); tick += 1 }
                            .disabled(SettingsStore.shared.cookie(p) == nil)
                    }
                }
            }
            Section {
                HStack {
                    Button("Paste from Clipboard") {
                        guard let t = NSPasteboard.general.string(forType: .string) else { message = "The clipboard is empty."; return }
                        do {
                            if case .page(let oj, let data) = try ClipboardPayload.parse(t), let db = app?.db {
                                let summary = try PageImport.run(db, oj: oj, data: data)
                                NSPasteboard.general.clearContents()
                                message = "Imported \(summary)."
                                app?.loadData()
                                return
                            }
                            let p = try CookieImport.importPayload(t)
                            NSPasteboard.general.clearContents()
                            message = "\(p.name) sign-in saved. Syncing \(p.name)…"
                            tick += 1
                            app?.startSync(full: false, only: [p]) { r in
                                message = r.ok ? "\(p.name) sign-in saved and verified ✓" : "\(p.name) saved, but the sync failed — see the log in the main window."
                            }
                        } catch { message = error.localizedDescription }
                    }
                    Spacer()
                }
                if !message.isEmpty { Text(message).font(.callout).foregroundColor(.secondary) }
            } footer: {
                Text("Cookies are stored in your macOS Keychain and are only ever sent to the site they came from.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .cookiesChanged)) { _ in tick += 1 }
    }
}

// MARK: - Ratings

struct RatingsTab: View {
    weak var app: AppDelegate?
    @ObservedObject var store = SettingsStore.shared
    @State private var key = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Text("SolveLog charts official difficulties automatically: Luogu levels, Codeforces ratings, AtCoder Problems difficulty, CodeChef difficulty and Project Euler levels. Optionally, clist.by adds one rating scale across judges (and is the only source for UOJ).")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Section("clist.by (optional)") {
                TextField("Username", text: $store.settings.clistUsername)
                SecureField("API key", text: $key, prompt: Text(store.clistAPIKey == nil ? "not set" : "saved — type to replace"))
                HStack {
                    Button("Save Key") { Keychain.set("clist.apikey", key.trimmed.isEmpty ? nil : key.trimmed); key = ""; status = "Saved." }
                        .disabled(key.trimmed.isEmpty)
                    Button("Remove Key") { Keychain.set("clist.apikey", nil); status = "Removed." }
                        .disabled(store.clistAPIKey == nil)
                    Link("Get an API key", destination: URL(string: "https://clist.by/api/v4/doc/")!)
                    Spacer()
                    Button(busy ? "Downloading…" : "Refresh clist Ratings Now") {
                        guard let db = app?.db else { return }
                        busy = true; status = "Downloading clist ratings (about 5 minutes; the free API allows 10 requests a minute)…"
                        Task {
                            do { try await Ratings.clist(db, force: true); status = "clist ratings updated." }
                            catch { status = "clist failed: \(error.localizedDescription)" }
                            busy = false
                            app?.loadData()
                        }
                    }
                    .disabled(busy || store.clistAPIKey == nil || store.settings.clistUsername.isEmpty)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundColor(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Data

struct DataTab: View {
    weak var app: AppDelegate?
    @State private var message = ""

    var body: some View {
        Form {
            Section("Submissions") {
                HStack {
                    Button("Export…") { exportSubmissions() }
                    Button("Import…") { importSubmissions() }
                    Spacer()
                }
                Text("Back up every stored submission as CSV or JSON, or restore a SolveLog export (merges by platform + submission id).")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Settings") {
                HStack {
                    Button("Export Settings…") { exportSettings() }
                    Button("Import Settings…") { importSettings() }
                    Spacer()
                }
                Text("Handles and options only. Cookies and API keys stay in this Mac's Keychain and are never exported.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Storage") {
                HStack {
                    Button("Show Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.shared.directory]) }
                    Button("Full Re-sync") { app?.startSync(full: true) }
                    Spacer()
                    Button("Delete All Data…", role: .destructive) { deleteAll() }
                }
            }
            if !message.isEmpty { Section { Text(message).font(.callout) } }
        }
        .formStyle(.grouped)
    }

    func exportSubmissions() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText, .json]
        p.nameFieldStringValue = "solvelog-submissions.csv"
        p.message = "Use a .json name to export JSON instead of CSV."
        guard p.runModal() == .OK, let url = p.url, let db = app?.db else { return }
        do { message = "Exported \(try ImportExport.exportSubmissions(db, to: url)) submissions." }
        catch { message = "Export failed: \(error.localizedDescription)" }
    }

    func importSubmissions() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.commaSeparatedText, .json]
        guard p.runModal() == .OK, let url = p.url, let db = app?.db else { return }
        do { message = "Imported \(try ImportExport.importSubmissions(db, from: url)) submissions."; app?.loadData() }
        catch { message = "Import failed: \(error.localizedDescription)" }
    }

    func exportSettings() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = "solvelog-settings.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try ImportExport.exportSettings(to: url); message = "Settings exported (without cookies or keys)." }
        catch { message = "Export failed: \(error.localizedDescription)" }
    }

    func importSettings() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try ImportExport.importSettings(from: url); message = "Settings imported. Reopen the Accounts tab to see them." }
        catch { message = "Import failed: \(error.localizedDescription)" }
    }

    func deleteAll() {
        let a = NSAlert()
        a.messageText = "Delete all stored submissions and ratings?"
        a.informativeText = "This cannot be undone. Your accounts, cookies and keys are kept, so the next sync downloads everything again."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn, let db = app?.db else { return }
        do { try db.deleteAll(); message = "All data deleted."; app?.loadData() }
        catch { message = "Delete failed: \(error.localizedDescription)" }
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("SolveLog").font(.largeTitle).bold()
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").foregroundColor(.secondary)
            Text("Tracks your submissions on Codeforces, AtCoder, Luogu, Project Euler, CodeChef, LibreOJ and UOJ — locally, on your Mac.")
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("Free software under the GNU General Public License v3 or later. It comes with ABSOLUTELY NO WARRANTY.")
                .font(.caption).multilineTextAlignment(.center).foregroundColor(.secondary)
            Text("SolveLog is not affiliated with any of the judges it reads from. It fetches only your own data, slowly and politely.")
                .font(.caption).multilineTextAlignment(.center).foregroundColor(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
