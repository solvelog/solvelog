// SolveLog — Copyright (C) 2026 SolveLog contributors — GPL-3.0-or-later
import Cocoa
import SwiftUI
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var settingsWindow: NSWindow?
    var db: Database!
    var engine: SyncEngine!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            db = try Database(url: SettingsStore.shared.directory.appendingPathComponent("solvelog.db"))
        } catch {
            let a = NSAlert(); a.messageText = "SolveLog could not open its database"; a.informativeText = error.localizedDescription
            a.runModal(); NSApp.terminate(nil); return
        }
        engine = SyncEngine(db: db)
        buildMenu()
        applyTheme(SettingsStore.shared.settings.theme)

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "app")
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SolveLog"
        window.minSize = NSSize(width: 840, height: 560)
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("SolveLogMainWindow")
        window.makeKeyAndOrderFront(nil)

        if let page = Self.pageURL() {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        NSApp.activate(ignoringOtherApps: true)
        if SettingsStore.shared.configuredPlatforms().isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showSettings() }   // first run
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// index.html lives in the app bundle; when running with `swift run` fall back to the source tree.
    static func pageURL() -> URL? {
        if let u = Bundle.main.url(forResource: "index", withExtension: "html") { return u }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/web/index.html")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - menu

    func buildMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String, mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        let appMenu = NSMenu()
        appMenu.addItem(item("About SolveLog", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings), ",", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide SolveLog", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Quit SolveLog", #selector(NSApplication.terminate(_:)), "q"))
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        let data = NSMenu(title: "Data")
        data.addItem(item("Sync", #selector(menuSync), "s", target: self))
        data.addItem(item("Full Re-sync", #selector(menuFullSync), "s", mods: [.command, .shift], target: self))
        data.addItem(item("Reload", #selector(menuReload), "r", target: self))
        data.addItem(.separator())
        data.addItem(item("Import Cookie from Clipboard", #selector(menuPasteCookie), "v", mods: [.command, .shift], target: self))
        data.addItem(item("Show Data Folder", #selector(menuReveal), "", target: self))
        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        for (menu, title) in [(appMenu, "SolveLog"), (edit, "Edit"), (data, "Data"), (win, "Window")] {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = menu
            main.addItem(i)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    @objc func menuSync() { startSync(full: false) }
    @objc func menuFullSync() { startSync(full: true) }
    @objc func menuReload() { loadData() }
    @objc func menuReveal() { NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.shared.directory]) }
    @objc func menuPasteCookie() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        importCookie(text)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(app: self)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "SolveLog Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyTheme(_ v: String) {
        switch v {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - page bridge

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        js("window.__setTheme && window.__setTheme(\(jsString(SettingsStore.shared.settings.theme)))")
        if SettingsStore.shared.settings.syncOnLaunch && !SettingsStore.shared.configuredPlatforms().isEmpty {
            startSync(full: false, automatic: true)
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "load": loadData()
        case "sync": startSync(full: false)
        case "settings": showSettings()
        case "setCookie": if let p = body["payload"] as? String { importCookie(p) }
        case "theme":
            if let v = body["value"] as? String, ["auto", "light", "dark"].contains(v) {
                SettingsStore.shared.settings.theme = v
                applyTheme(v)
            }
        case "open":
            if let s = body["url"] as? String, let u = URL(string: s), u.scheme == "https" || u.scheme == "http" {
                NSWorkspace.shared.open(u)
            }
        default: break
        }
    }

    func js(_ code: String) { DispatchQueue.main.async { self.web?.evaluateJavaScript(code, completionHandler: nil) } }

    func jsString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)) ?? Data("\"\"".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    func loadData() {
        let db = self.db!
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payload = try Dashboard.payload(db)
                let data = try JSONSerialization.data(withJSONObject: payload)
                self.js("render(\(String(decoding: data, as: UTF8.self)))")
            } catch {
                self.js("loadError(\(self.jsString(error.localizedDescription)))")
            }
        }
    }

    func startSync(full: Bool, only: [Platform]? = nil, automatic: Bool = false, completion: ((SyncResult) -> Void)? = nil) {
        js("window.syncStarted && window.syncStarted()")
        Task {
            let r = await engine.sync(only: only, full: full, automatic: automatic)
            await MainActor.run {
                self.js("syncDone(\(r.ok), \(self.jsString(r.log)))")
                self.loadData()
                completion?(r)
            }
        }
    }

    /// Paste from the userscript. A page (Project Euler) is parsed locally; a cookie goes to the Keychain
    /// and that platform is synced once to prove it works.
    func importCookie(_ text: String) {
        do {
            if case .page(let oj, let data) = try ClipboardPayload.parse(text) {
                let summary = try PageImport.run(db, oj: oj, data: data)
                NSPasteboard.general.clearContents()
                js("cookieDone(true, \(jsString(oj)), \(jsString("Imported \(summary).")))")
                loadData()
                return
            }
            let p = try CookieImport.importPayload(text)
            NSPasteboard.general.clearContents()   // the cookie is a credential; don't leave it on the clipboard
            NotificationCenter.default.post(name: .cookiesChanged, object: nil)
            js("cookieImporting && cookieImporting(\(jsString(p.name)))")
            startSync(full: false, only: [p]) { r in
                self.js("cookieDone(\(r.ok), \(self.jsString(p.rawValue)), \(self.jsString(r.log)))")
            }
        } catch {
            js("cookieDone(false, '', \(jsString(error.localizedDescription)))")
        }
    }
}

extension Notification.Name {
    static let cookiesChanged = Notification.Name("SolveLogCookiesChanged")
}
