import AppKit
import ApplicationServices

final class TextHelper: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let reader = SelectionSpeechReader()
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.title = "文字助手"
        let menu = NSMenu()
        for (title, action) in [
            ("识别截图中的文字与公式", #selector(capture)),
            ("朗读所选文字", #selector(speak)),
            ("停止朗读", #selector(stop)),
            ("退出", #selector(quit))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        status.menu = menu
    }

    @objc private func capture() {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showError("请在系统设置中允许录屏，然后重新打开文字助手。")
            return
        }
        busy = true
        status.button?.title = "框选截图…"
        OCRRegionCapture.begin { result in
            switch result {
            case .success(let url):
                if let url { self.recognize(url) }
                else { self.finish() }
            case .failure(let error):
                self.finish(error: error.localizedDescription)
            }
        }
    }

    private func recognize(_ screenshot: URL) {
        status.button?.title = "识别中…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [Bundle.main.resourceURL!.appendingPathComponent("ocr_capture.py").path, "--file", screenshot.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: screenshot)
            finish(error: error.localizedDescription)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: screenshot)
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            DispatchQueue.main.async {
                guard let text = result?["text"] as? String, !text.isEmpty else {
                    self.finish(error: result?["error"] as? String ?? "模型未返回识别结果。")
                    return
                }
                NSPasteboard.general.clearContents()
                let copied = NSPasteboard.general.setString(text, forType: .string)
                self.finish(error: copied ? nil : "无法复制识别结果。", copied: copied)
            }
        }
    }

    private func finish(error: String? = nil, copied: Bool = false) {
        busy = false
        status.button?.title = copied ? "已复制 ✓" : "文字助手"
        if let error { showError(error) }
        if copied {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !self.busy { self.status.button?.title = "文字助手" }
            }
        }
    }

    @objc private func speak() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            showError("请在系统设置中授予辅助功能权限。")
            return
        }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            showError("请先在其他应用中选中文字。")
            return
        }
        let element = focused as! AXUIElement
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != "AXSecureTextField" else { return }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("当前应用没有提供选中文字，请换一个可选取文字的应用。")
            return
        }
        reader.start(text)
    }

    @objc private func stop() { reader.stop() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "文字助手"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = TextHelper()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
