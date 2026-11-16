import AppKit

final class ViewerWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?
    private static let homeFrameKey = "ViewerHomeFrame"
    private var displayAspect: CGFloat?

    override func close() {
        super.close()
        onClose?()
    }

    func restoreHomeFrame() {
        center()
        if let saved = UserDefaults.standard.string(forKey: Self.homeFrameKey),
           let bounds = (screen ?? NSScreen.main)?.visibleFrame {
            let frame = NSRectFromString(saved)
            if frame.width >= minSize.width && frame.height >= minSize.height {
                setFrame(contained(frame, in: bounds), display: true)
            }
        }
        delegate = self
    }

    func fitDisplay(_ aspect: CGFloat?) {
        guard displayAspect != aspect else { return }
        if displayAspect == nil { saveHomeFrame() }
        displayAspect = aspect

        guard let bounds = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let target: NSRect
        if let aspect {
            let preferred = NSRect(x: 0, y: 0,
                                   width: min(bounds.width * 0.78, 1200),
                                   height: min(bounds.height * 0.78, 820))
            let centered = preferred.offsetBy(dx: bounds.midX - preferred.midX,
                                              dy: bounds.midY - preferred.midY)
            target = largestFrame(aspect: aspect, in: centered)
        } else if let saved = UserDefaults.standard.string(forKey: Self.homeFrameKey) {
            target = contained(NSRectFromString(saved), in: bounds)
        } else {
            return
        }
        setFrame(target, display: true, animate: false)
    }

    func windowDidMove(_ notification: Notification) { saveHomeFrame() }
    func windowDidResize(_ notification: Notification) { saveHomeFrame() }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard let aspect = displayAspect, let bounds = screen?.visibleFrame else { return defaultFrame }
        return largestFrame(aspect: aspect, in: bounds)
    }

    func windowWillResize(_ sender: NSWindow, to proposed: NSSize) -> NSSize {
        guard let aspect = displayAspect else { return proposed }
        let horizontalChange = abs(proposed.width - frame.width)
        let verticalChange = abs(proposed.height - frame.height)
        let width = horizontalChange >= verticalChange * aspect
            ? proposed.width : (proposed.height - Viewer.barHeight) * aspect
        let minimum = max(minSize.width, (minSize.height - Viewer.barHeight) * aspect)
        let maximum = screen.map { largestFrame(aspect: aspect, in: $0.visibleFrame).width } ?? .greatestFiniteMagnitude
        return fittedSize(width: min(max(width, minimum), maximum), aspect: aspect)
    }

    private func saveHomeFrame() {
        guard displayAspect == nil, isVisible, !styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.homeFrameKey)
    }

    private func largestFrame(aspect: CGFloat, in bounds: NSRect) -> NSRect {
        let width = min(bounds.width, max(1, bounds.height - Viewer.barHeight) * aspect)
        let size = fittedSize(width: width, aspect: aspect)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func contained(_ rect: NSRect, in bounds: NSRect) -> NSRect {
        let width = min(rect.width, bounds.width), height = min(rect.height, bounds.height)
        return NSRect(x: min(max(rect.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(rect.minY, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }

    private func fittedSize(width: CGFloat, aspect: CGFloat) -> NSSize {
        NSSize(width: width, height: width / aspect + Viewer.barHeight)
    }
}
