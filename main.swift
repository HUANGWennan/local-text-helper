import AppKit
import ApplicationServices

final class TextHelper: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let reader = SelectionSpeechReader()
    private var busy = false
    private var panelPaused = false
    private var showingPreview = false
    private let panel = FloatingSelectionPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.title = "文字助手"
        panel.isSuppressed = { [weak self] in
            guard let self else { return true }
            return self.busy || self.panelPaused || self.showingPreview
        }
        panel.onAction = { [weak self] mode, selection in self?.run(mode, selection: selection) }
        let menu = NSMenu()
        for (title, action) in [
            ("识别截图中的文字与公式", #selector(capture)),
            ("朗读所选文字", #selector(speak)),
            ("停止朗读", #selector(stop)),
            ("暂停／继续浮动面板", #selector(togglePanel)),
            ("启用选区功能", #selector(requestAccessibility)),
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
        panel.dismiss()
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

    @objc private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            showError("请在系统设置中授予辅助功能权限。")
        }
    }

    @objc private func speak() {
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        guard let selection = TextSelection.read() else {
            showError("请先在支持辅助功能的应用中选中文字。")
            return
        }
        reader.start(selection.text)
    }

    @objc private func togglePanel() {
        panelPaused.toggle()
        panel.dismiss()
        if !panelPaused { panel.resume() }
    }

    private func run(_ mode: String, selection: TextSelection) {
        guard !busy else { return }
        if mode == "speak" {
            if reader.isSpeaking { reader.stop() } else { reader.start(selection.text) }
            return
        }
        if mode == "todo" {
            runHelper("todo_public.py", mode: "extract", payload: ["text": selection.text]) { result in
                self.previewTasks(result)
            }
        } else {
            runHelper("process_text.py", mode: mode, payload: ["text": selection.text]) { result in
                guard let text = result["text"] as? String else { self.showError("模型未返回文字。"); return }
                self.previewText(text, selection: selection)
            }
        }
    }

    private func runHelper(_ script: String, mode: String, payload: [String: Any],
                           completion: @escaping ([String: Any]) -> Void) {
        guard let scriptURL = Bundle.main.resourceURL?.appendingPathComponent(script),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            showError("无法准备文字处理请求。")
            return
        }
        busy = true
        status.button?.title = "处理中…"
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path, mode]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { finish(error: error.localizedDescription); return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
            DispatchQueue.main.async {
                self.finish()
                if let error = result?["error"] as? String {
                    self.showError(error)
                } else if let result {
                    completion(result)
                } else {
                    self.showError("文字处理程序未返回结果。")
                }
            }
        }
    }

    private func previewText(_ text: String, selection: TextSelection) {
        let alert = NSAlert()
        alert.messageText = "预览处理结果"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 470, height: 210))
        scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.font = NSFont.systemFont(ofSize: 14)
        editor.string = text
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.addButton(withTitle: "复制")
        alert.addButton(withTitle: "替换原选区")
        alert.addButton(withTitle: "取消")
        let choice = runPreview(alert)
        if choice == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(editor.string, forType: .string)
        } else if choice == .alertSecondButtonReturn, !selection.replace(with: editor.string) {
            showError("原选区已变化，或当前应用不支持替换。请重新选择文字或使用复制。")
        }
    }

    private func previewTasks(_ result: [String: Any]) {
        guard let events = result["events"] as? [[String: Any]], !events.isEmpty else {
            showError("未识别到可加入 To Do 的任务。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "确认加入 Microsoft To Do"
        alert.informativeText = result["text"] as? String ?? ""
        let eligible = events.filter { event in
            guard let issues = event["issues"] as? [String] else { return false }
            return issues.isEmpty
        }
        let canCreate = eligible.count == events.count
        if canCreate { alert.addButton(withTitle: "确认添加") }
        alert.addButton(withTitle: canCreate ? "取消" : "关闭")
        guard runPreview(alert) == .alertFirstButtonReturn, canCreate else { return }
        runHelper("todo_public.py", mode: "create", payload: ["events": eligible]) { result in
            let report = NSAlert()
            report.messageText = "Microsoft To Do 处理结果"
            report.informativeText = result["text"] as? String ?? "处理已结束。"
            report.addButton(withTitle: "好")
            _ = self.runPreview(report)
        }
    }

    private func runPreview(_ alert: NSAlert) -> NSApplication.ModalResponse {
        showingPreview = true
        defer { showingPreview = false }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    @objc private func stop() { reader.stop() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "文字助手"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        _ = runPreview(alert)
    }
}

let app = NSApplication.shared
let delegate = TextHelper()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
