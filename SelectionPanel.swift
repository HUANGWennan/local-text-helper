import AppKit
import ApplicationServices

struct TextSelection {
    let pid: pid_t
    let element: AXUIElement
    let text: String

    static func read() -> TextSelection? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.12)
        guard let value = attribute(root, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let focus = value as! AXUIElement
        guard !isSecure(focus) else { return nil }
        if let text = selectedText(focus) {
            return TextSelection(pid: app.processIdentifier, element: focus, text: text)
        }
        let role = attribute(focus, kAXRoleAttribute) as? String
        guard ["AXWebArea", "AXGroup", "AXTextArea", "AXScrollArea"].contains(role ?? "") else { return nil }
        var pending = (attribute(focus, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed().map { $0 }
        var match: TextSelection?
        for _ in 0..<160 {
            guard let element = pending.popLast() else { break }
            if isSecure(element) { continue }
            if let text = selectedText(element) {
                if match != nil { return nil }
                match = TextSelection(pid: app.processIdentifier, element: element, text: text)
                continue
            }
            pending.append(contentsOf: (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed())
        }
        return match
    }

    func matches(_ other: TextSelection) -> Bool {
        pid == other.pid && text == other.text && CFEqual(element, other.element)
    }

    func replace(with result: String) -> Bool {
        guard !Self.isSecure(element), Self.selectedText(element) == text,
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let root = AXUIElementCreateApplication(pid)
        guard let originalWindow = Self.attribute(element, kAXWindowAttribute),
              let currentWindow = Self.attribute(root, kAXFocusedWindowAttribute),
              CFEqual(originalWindow, currentWindow) else { return false }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success,
              writable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, result as CFString) == .success else {
            return false
        }
        app.activate(options: [])
        return true
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        attribute(element, kAXSubroleAttribute) as? String == "AXSecureTextField"
    }

    private static func selectedText(_ element: AXUIElement) -> String? {
        guard let text = attribute(element, kAXSelectedTextAttribute) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 24000 else { return nil }
        return text
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

final class FloatingSelectionPanel: NSObject {
    private let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 594, height: 52),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var timer: Timer?
    private var candidate: TextSelection?
    private var dismissed: TextSelection?
    private var changedAt = Date()
    var onAction: ((String, TextSelection) -> Void)?
    var isSuppressed: (() -> Bool)?

    override init() {
        super.init()
        window.level = .floating
        window.hasShadow = true
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let actions = [("英文润色", "english"), ("译为中文", "chinese"), ("智能清理", "clean"), ("加入 To Do", "todo"), ("朗读", "speak")]
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.0, target: self, action: #selector(selectAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(action.1)
            button.frame = NSRect(x: 8 + index * 110, y: 9, width: 106, height: 34)
            window.contentView?.addSubview(button)
        }
        let close = NSButton(title: "×", target: self, action: #selector(dismiss))
        close.frame = NSRect(x: 558, y: 9, width: 28, height: 34)
        window.contentView?.addSubview(close)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    deinit { timer?.invalidate() }

    @objc func dismiss() {
        dismissed = candidate
        window.orderOut(nil)
    }

    func resume() { dismissed = nil; candidate = nil }

    private func poll() {
        guard isSuppressed?() != true else { window.orderOut(nil); return }
        guard let selection = TextSelection.read() else {
            window.orderOut(nil)
            candidate = nil
            dismissed = nil
            return
        }
        guard candidate?.matches(selection) == true else {
            candidate = selection
            changedAt = Date()
            window.orderOut(nil)
            if dismissed?.matches(selection) != true { dismissed = nil }
            return
        }
        guard !window.isVisible, dismissed?.matches(selection) != true,
              Date().timeIntervalSince(changedAt) >= 0.35 else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = max(visible.minX, min(point.x, visible.maxX - window.frame.width))
        let y = max(visible.minY, min(point.y - window.frame.height - 10, visible.maxY - window.frame.height))
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.orderFrontRegardless()
    }

    @objc private func selectAction(_ sender: NSButton) {
        guard let mode = sender.identifier?.rawValue, let selection = candidate,
              TextSelection.read()?.matches(selection) == true else { dismiss(); return }
        dismiss()
        onAction?(mode, selection)
    }
}
