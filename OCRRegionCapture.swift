import AppKit
import ScreenCaptureKit

// Capture runs in the signed, authorized app; Python only reads the PNG.
final class OCRRegionCapture {
    private static var current: OCRRegionCapture?
    private var windows: [NSWindow] = []
    private var completion: ((Result<URL?, Error>) -> Void)?
    static func begin(_ completion: @escaping (Result<URL?, Error>) -> Void) {
        let picker = OCRRegionCapture(); current = picker; picker.completion = completion
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let window = OCRSelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver; window.isOpaque = false; window.backgroundColor = .clear
            window.sharingType = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = OCRSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.finished = { [weak picker] rect in
                guard let picker = picker else { return }
                guard let rect = rect else { picker.finish(.success(nil)); return }
                let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                picker.capture(global, scale: screen.backingScaleFactor)
            }
            window.contentView = view; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
            picker.windows.append(window)
        }
        NSCursor.crosshair.push()
    }
    private func hide() {
        for window in windows { window.orderOut(nil) }; windows.removeAll()
        NSCursor.pop()
    }
    private func finish(_ result: Result<URL?, Error>) {
        if !windows.isEmpty { hide() }
        let callback = completion; completion = nil; Self.current = nil; callback?(result)
    }
    private func capture(_ region: CGRect, scale: CGFloat) {
        hide()
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = CGRect(x: region.minX, y: top - region.maxY, width: region.width, height: region.height)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            if #available(macOS 26.0, *) {
                let config = SCScreenshotConfiguration()
                config.width = Int(rect.width * scale); config.height = Int(rect.height * scale)
                config.showsCursor = false; config.dynamicRange = .sdr
                SCScreenshotManager.captureScreenshot(rect: rect, configuration: config) { output, error in
                    DispatchQueue.main.async {
                        if let error = error { self.finish(.failure(error)); return }
                        guard let image = output?.sdrImage,
                              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                            self.finish(.failure(NSError(domain: "系统没有返回截图，请检查文字助手的录屏权限。", code: 1))); return
                        }
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-text-helper-ocr-" + UUID().uuidString + ".png")
                        do { try png.write(to: url, options: .atomic); self.finish(.success(url)) }
                        catch { self.finish(.failure(error)) }
                    }
                }
            } else {
                self.finish(.failure(NSError(domain: "此截图方式需要 macOS 26 或更新版本。", code: 2)))
            }
        }
    }
}
private final class OCRSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
private final class OCRSelectionView: NSView {
    var finished: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.16).setFill(); bounds.fill()
        if !selection.isEmpty {
            NSColor.white.withAlphaComponent(0.18).setFill(); selection.fill()
            NSColor.systemBlue.setStroke(); let path = NSBezierPath(rect: selection); path.lineWidth = 2; path.stroke()
        }
        let label = "拖动框选文字与公式 · Esc 取消"
        label.draw(at: NSPoint(x: 24, y: bounds.height - 54), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start = start else { return }; let end = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x,end.x), y: min(start.y,end.y), width: abs(end.x-start.x), height: abs(end.y-start.y)); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        let callback = finished; finished = nil
        callback?(selection.width >= 4 && selection.height >= 4 ? selection : nil)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { let callback = finished; finished = nil; callback?(nil) } }
}
