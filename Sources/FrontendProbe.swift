import AppKit
import QuartzCore

/// Opt-in measurements use the same wallpaper actions and drawable presentations as the app.
enum FrontendProbe {
    static let report = ProcessInfo.processInfo.environment["VMLAB_FRONTEND_REPORT"]
    private static let lock = NSLock()
    private static var started = 0.0
    private static var visible: Double?
    private static var firstPresentation: Double?
    private static var selections: [ObjectIdentifier: Double] = [:]
    private static var presentedSelections = Set<Double>()
    private static var switchTimes: [Double] = []
    private static var gpuTimes: [Double] = []
    private static var eventDelays: [Double] = []
    private static var scrollTimes: [Double] = []
    private static var scrollIntervals: [Double] = []
    private static var scrolling = false
    private static var scrollWallpaperDraws = 0
    private static var columnCount = 0
    private static var columnsAligned = false
    private static var independentColumnScroll = false

    static func wallpaperRendered() {
        guard report != nil else { return }
        lock.lock()
        if scrolling { scrollWallpaperDraws += 1 }
        lock.unlock()
    }
    private static var revealAnimations = 0
    private static var runtimeIcons: [String: Bool] = [:]
    private static var milestones: [String: Double] = [:]
    private static var activity: NSObjectProtocol?
    private static var heartbeat: DispatchSourceTimer?

    static func revealPlayed() {
        guard report != nil else { return }
        lock.lock(); revealAnimations += 1; lock.unlock()
    }
    static func iconPrepared(_ resource: String?, image: CGImage) {
        guard report != nil, let resource, ["Docker.png", "Kubernetes.png"].contains(resource),
              let bytes = image.dataProvider?.data as Data? else { return }
        let filled = stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
        lock.lock(); runtimeIcons[resource] = filled; lock.unlock()
    }
    static func mark(_ name: String) {
        guard report != nil else { return }
        lock.lock()
        if milestones[name] == nil { milestones[name] = (CACurrentMediaTime() - started) * 1000 }
        lock.unlock()
    }
    static func start() {
        guard report != nil else { return }
        started = CACurrentMediaTime()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                        reason: "VM Lab interactive performance validation")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vmlab.ui-probe", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler {
            let sent = CACurrentMediaTime()
            DispatchQueue.main.async {
                let delay = (CACurrentMediaTime() - sent) * 1000
                lock.lock(); eventDelays.append(delay); lock.unlock()
            }
        }
        heartbeat = timer
        timer.resume()
    }
    static func beginInteraction() {
        lock.lock()
        selections.removeAll()
        presentedSelections.removeAll()
        switchTimes.removeAll()
        eventDelays.removeAll()
        lock.unlock()
    }
    static func windowVisible() {
        guard report != nil else { return }
        lock.lock(); visible = (CACurrentMediaTime() - started) * 1000; lock.unlock()
    }
    static func selected(_ image: CGImage, at time: Double = CACurrentMediaTime()) {
        guard report != nil else { return }
        lock.lock(); selections[ObjectIdentifier(image)] = time; lock.unlock()
    }
    static func selectionTime(for image: CGImage) -> Double? {
        guard report != nil else { return nil }
        lock.lock(); defer { lock.unlock() }
        return selections[ObjectIdentifier(image)]
    }
    static func presented(selection: Double?, at time: Double) {
        guard report != nil, time > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if firstPresentation == nil { firstPresentation = (time - started) * 1000 }
        if let selection, presentedSelections.insert(selection).inserted {
            switchTimes.append((time - selection) * 1000)
        }
    }
    static func gpu(seconds: Double) {
        guard report != nil, seconds > 0 else { return }
        lock.lock(); gpuTimes.append(seconds * 1000); lock.unlock()
    }
    @MainActor static func exerciseScroll() async {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews { if let scroll = find(child) { return scroll } }
            return nil
        }
        guard let scroll = NSApp.windows.filter(\.isVisible).compactMap({ $0.contentView.flatMap(find) }).first,
              let document = scroll.documentView else { return }
        lock.withLock { scrolling = true }
        var previous = CACurrentMediaTime()
        for step in 0..<240 {
            let start = CACurrentMediaTime()
            if step > 0 { scrollIntervals.append((start - previous) * 1000) }
            previous = start
            let distance = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let fraction = CGFloat(step < 120 ? step : 239 - step) / 119
            scroll.contentView.scroll(to: NSPoint(x: 0, y: distance * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.layoutSubtreeIfNeeded()
            CATransaction.flush()
            scrollTimes.append((CACurrentMediaTime() - start) * 1000)
            try? await Task.sleep(for: .milliseconds(8))
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            let current = (view as? NSScrollView).map { [$0] } ?? []
            return current + view.subviews.flatMap(scrollViews)
        }
        let panes = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(scrollViews)
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        columnCount = panes.count
        let rectangles = panes.map { $0.convert($0.bounds, to: nil) }
        if rectangles.count == 3 {
            columnsAligned = rectangles.allSatisfy {
                $0.width > 50 && abs($0.width - rectangles[0].width) < 2 && abs($0.maxY - rectangles[0].maxY) < 2
            } && rectangles[0].maxX <= rectangles[1].minX + 1 && rectangles[1].maxX <= rectangles[2].minX + 1
            independentColumnScroll = true
            for pane in panes {
                let others = panes.filter { $0 !== pane }
                let previous = others.map { $0.contentView.bounds.origin }
                let distance = max(0, (pane.documentView?.bounds.height ?? 0) - pane.contentView.bounds.height)
                pane.contentView.scroll(to: NSPoint(x: 0, y: min(60, distance)))
                pane.reflectScrolledClipView(pane.contentView)
                independentColumnScroll = independentColumnScroll && others.map { $0.contentView.bounds.origin } == previous
            }
            for step in 0..<120 {
                for pane in panes {
                    let distance = max(0, (pane.documentView?.bounds.height ?? 0) - pane.contentView.bounds.height)
                    let fraction = CGFloat(step < 60 ? step : 119 - step) / 59
                    pane.contentView.scroll(to: NSPoint(x: 0, y: distance * fraction))
                    pane.reflectScrolledClipView(pane.contentView)
                    pane.layoutSubtreeIfNeeded()
                }
                CATransaction.flush()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        lock.withLock { scrolling = false }
    }

    static func finish() {
        guard let report else { return }
        heartbeat?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        lock.lock()
        let data: [String: Any] = ["windowVisibleMS": visible ?? -1,
                                   "firstMetalPresentationMS": firstPresentation ?? -1,
                                   "wallpaperPresentationMS": switchTimes,
                                   "gpuRenderMS": gpuTimes, "mainQueueDelayMS": eventDelays, "scrollMutationMS": scrollTimes, "scrollIntervalMS": scrollIntervals, "scrollWallpaperDraws": scrollWallpaperDraws, "columnCount": columnCount, "columnsAligned": columnsAligned, "independentColumnScroll": independentColumnScroll, "milestonesMS": milestones, "revealAnimationCount": revealAnimations, "runtimeIcons": runtimeIcons]
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: URL(fileURLWithPath: report), options: .atomic)
            }
        }
    }
}
