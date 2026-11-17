import AppKit
import Darwin
import Foundation
import UserNotifications
import WebKit

// The transfer worker uses the system's atomic, no-replace rename.
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--publish" {
    let source = CommandLine.arguments[2]
    let destination = CommandLine.arguments[3]
    let result = source.withCString { from in
        destination.withCString { to in
            renamex_np(from, to, UInt32(RENAME_EXCL))
        }
    }
    exit(result == 0 ? 0 : 1)
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--trash" {
    do { try FileManager.default.trashItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), resultingItemURL: nil); exit(0) }
    catch { exit(1) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    private var worker: Process?
    private let commands = Pipe()
    private let responsePipe = Pipe()
    private var readBuffer = Data()
    private var events: [[String: Any]] = []
    private var ready = false
    private var active = false
    private var lockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "downloads")
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Dropbox Downloader"
        window.contentMinSize = NSSize(width: 470, height: 500)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let html = Bundle.main.url(forResource: "interface", withExtension: "html") else {
            showAlert("The app's interface is missing. Rebuild it from the complete folder.")
            return
        }
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    private func makeMenu() {
        let bar = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Dropbox Downloader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu
        bar.addItem(app)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        bar.addItem(edit)
        NSApp.mainMenu = bar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !active { return .terminateNow }
        showAlert("A download is active. Click Pause and wait for it to finish saving its progress before quitting.")
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? commands.fileHandleForWriting.close()
        if lockFD >= 0 { Darwin.close(lockFD) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        for item in events { send(item) }
        events.removeAll()
        if worker == nil { startWorker() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let requested = action.request.url?.standardizedFileURL
        let page = Bundle.main.url(forResource: "interface", withExtension: "html")?.standardizedFileURL
        decisionHandler(requested == page && requested != nil ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.reload()
        write(["action": "snapshot"])
    }

    private func startWorker() {
        let fm = FileManager.default
        let bundledNode = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("node").path
        let nodes = [bundledNode].compactMap { $0 } + ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/opt/local/bin/node"]
        guard let node = nodes.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            send(["type": "error", "message": "Install Node.js and aria2 with brew install node aria2, then reopen the app."])
            return
        }
        do {
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
                .appendingPathComponent("Dropbox Downloader Mac", isDirectory: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let lock = support.appendingPathComponent("app.lock").path
            lockFD = Darwin.open(lock, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0 else {
                send(["type": "error", "message": "Could not open the app's local history."])
                return
            }
            _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(lockFD)
                lockFD = -1
                send(["type": "error", "message": "Dropbox Downloader is already open. Return to its original window."])
                return
            }
            guard let script = Bundle.main.url(forResource: "backend", withExtension: "mjs"),
                  let executable = Bundle.main.executableURL else {
                send(["type": "error", "message": "The app's download worker is missing. Rebuild from the complete folder."])
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
                ?? fm.homeDirectoryForCurrentUser.path
            process.arguments = [script.path, support.path, executable.path, downloads]
            process.standardInput = commands
            process.standardOutput = responsePipe
            process.standardError = FileHandle.nullDevice
            responsePipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                else { DispatchQueue.main.async { self?.receive(data) } }
            }
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.active = false
                    self?.send(["type": "disconnected", "message": "The download worker stopped. Reopen the app to check saved progress."])
                }
            }
            try process.run()
            worker = process
        } catch {
            send(["type": "error", "message": "The download worker could not start. Check the setup instructions."])
        }
    }

    private func receive(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 10) {
            let line = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if event["type"] as? String == "history" { active = event["active"] is String }
            if event["type"] as? String == "notification",
               let title = event["title"] as? String, let body = event["body"] as? String {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                )
            } else { send(event) }
        }
    }

    private func send(_ event: [String: Any]) {
        guard ready else { events.append(event); return }
        web.callAsyncJavaScript("window.receive(event)", arguments: ["event": event],
                                in: nil, in: .page, completionHandler: nil)
    }

    private func write(_ message: [String: Any]) {
        guard worker?.isRunning == true,
              var bytes = try? JSONSerialization.data(withJSONObject: message) else { return }
        bytes.append(10)
        do { try commands.fileHandleForWriting.write(contentsOf: bytes) }
        catch { send(["type": "error", "message": "Could not reach the download worker."]) }
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Dropbox Downloader"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any],
              let action = data["action"] as? String else { return }
        switch action {
        case "chooseFolder":
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    self.send(["type": "folder", "path": url.path])
                }
            }
        case "notificationPermission":
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if !granted {
                    DispatchQueue.main.async {
                        self.send(["type": "error", "message": "macOS notifications are off. You can enable them in System Settings."])
                    }
                }
            }
        case "start", "resume", "pause", "log", "reveal", "workingFolder", "clearPartials":
            if action == "start" || action == "resume" { active = true }
            write(data)
        default: break
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
