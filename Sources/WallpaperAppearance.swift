import AppKit
import ImageIO
import QuartzCore
import SwiftUI

enum WallpaperAppearance {
    private static let queue = DispatchQueue(label: "vmlab.wallpaper", qos: .userInitiated)
    private static let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    static func cached(_ version: String) -> CGImage? {
        images.object(forKey: version as NSString)
    }

    private static let iconQueue = DispatchQueue(label: "vmlab.wallpaper-icon", qos: .utility)

    static func load(_ version: String) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: decode(version)) }
        }
    }

    private static let preloadLock = NSLock()
    private static var preloaded = false
    private static let preloading = DispatchQueue(label: "vmlab.wallpaper-preload", qos: .utility)

    static func preload(startingAt version: String, versions: [String]) {
        preloadLock.lock()
        if preloaded { preloadLock.unlock(); return }
        preloaded = true
        preloadLock.unlock()
        let index = versions.firstIndex(of: version) ?? 0
        let ordered = Array(versions[index...]) + Array(versions[..<index])
        preloading.async {
            for version in ordered {
                autoreleasepool {
                    if let image = decode(version) { WallpaperGPU.shared.prepare(image) { _ in } }
                }
            }
        }
    }

    static func bootstrap() {
        let version = UserDefaults.standard.string(forKey: "wallpaperVersion") ?? "14"
        queue.async {
            if let image = decode(version) { WallpaperGPU.shared.prepare(image) { _ in } }
        }
    }

    private static func decode(_ version: String) -> CGImage? {
        let key = version as NSString
        if let image = images.object(forKey: key) { return image }
        guard let url = Bundle.main.url(forResource: version, withExtension: "jpg",
                                        subdirectory: "Wallpapers"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1440,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    static func renderIcon(_ image: CGImage) async -> CGImage? {
        await withCheckedContinuation { continuation in
            iconQueue.async { continuation.resume(returning: makeIcon(image)) }
        }
    }

    private static func makeIcon(_ image: CGImage) -> CGImage? {
        let wallpaper = NSImage(cgImage: image, size: .zero)
        guard let symbol = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 208, weight: .semibold)) else { return nil }

        let mark = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.setFill()
            bounds.fill(using: .sourceIn)
            return true
        }
        let icon = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { bounds in
            let tile = bounds.insetBy(dx: 32, dy: 32)
            let scale = max(tile.width / wallpaper.size.width, tile.height / wallpaper.size.height)
            let width = wallpaper.size.width * scale
            let height = wallpaper.size.height * scale

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: tile, xRadius: 98, yRadius: 98).addClip()
            wallpaper.draw(in: NSRect(x: tile.midX - width / 2, y: tile.midY - height / 2,
                                      width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.shadowBlurRadius = 14
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.57)
            shadow.set()
            mark.draw(at: NSPoint(x: bounds.midX - mark.size.width / 2,
                                  y: bounds.midY - mark.size.height / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @MainActor static func applyIcon(_ image: CGImage, version: String) {
        let icon = NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
        NSApp.applicationIconImage = icon

        let bundle = Bundle.main.bundleURL
        // Finder metadata and custom-icon writes can block independently of rendering.
        iconQueue.async {
            let icon = NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
            let versionKey = "FinderIconWallpaperVersion"
            let metadata = try? bundle.resourceValues(forKeys: [.customIconKey])
            if metadata?.customIcon != nil,
               UserDefaults.standard.string(forKey: versionKey) == version { return }
            if NSWorkspace.shared.setIcon(icon, forFile: bundle.path, options: []) {
                UserDefaults.standard.set(version, forKey: versionKey)
            }
        }
    }
}

private struct WallpaperCropSpace: EnvironmentKey {
    static let defaultValue = WallpaperSlice.coordinateSpace
}

private struct WallpaperCanvasSize: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    var wallpaperCropSpace: String {
        get { self[WallpaperCropSpace.self] }
        set { self[WallpaperCropSpace.self] = newValue }
    }
    var wallpaperCanvasSize: CGSize {
        get { self[WallpaperCanvasSize.self] }
        set { self[WallpaperCanvasSize.self] = newValue }
    }
}

struct WallpaperSlice: View {
    static let coordinateSpace = "vmLab wallpaper"
    let image: CGImage?
    var primary = false
    @Environment(\.displayScale) private var scale
    @Environment(\.wallpaperDithering) private var dither
    @Environment(\.wallpaperCanvasSize) private var canvasSize
    @Environment(\.wallpaperCropSpace) private var cropSpace

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named(cropSpace))
            // List crops are anchored to the document, so scrolling only moves existing layers.
            let originY = cropSpace == Self.coordinateSpace || canvasSize.height <= 0
                ? frame.minY : frame.minY.truncatingRemainder(dividingBy: canvasSize.height)
            let originX = cropSpace == Self.coordinateSpace || canvasSize.width <= 0
                ? frame.minX : frame.minX.truncatingRemainder(dividingBy: canvasSize.width)
            let region = CGRect(x: originX, y: originY, width: frame.width, height: frame.height)
            if let image, canvasSize.width > 0, canvasSize.height > 0 {
                MetalWallpaper(image: image, canvas: canvasSize, region: region,
                               dither: dither, scale: scale, primary: primary)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct WallpaperFilledTitle: View {
    let name: String
    let image: CGImage?
    let color: Color
    let font: Font
    private var title: some View {
        Text(name)
            .font(font)
            .lineLimit(1)
    }

    var body: some View {
        title.foregroundStyle(image == nil ? color : .clear)
            .overlay {
                if let image {
                    WallpaperSlice(image: image)
                    .mask { title }
                    .shadow(color: .black.opacity(0.65), radius: 1, y: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(name)
    }
}

private struct WallpaperDithering: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var wallpaperDithering: Bool {
        get { self[WallpaperDithering.self] }
        set { self[WallpaperDithering.self] = newValue }
    }
}

@MainActor final class WallpaperStore: ObservableObject {
    let picker = WallpaperPickerState()
    var version: String { picker.version }
    private var currentImage: CGImage?
    var image: CGImage? { currentImage }
    private var loading: Task<Void, Never>?
    private var icon: Task<Void, Never>?

    init() {
        if !Wallpaper.cycle.contains(where: { $0.id == version }) { picker.version = "14" }
        select(version)
    }

    func next() {
        let index = Wallpaper.cycle.firstIndex { $0.id == version } ?? 0
        select(Wallpaper.cycle[(index + 1) % Wallpaper.cycle.count].id)
    }

    func select(_ next: String) {
        guard Wallpaper.cycle.contains(where: { $0.id == next }) else { return }
        let requested = CACurrentMediaTime()
        loading?.cancel()
        icon?.cancel()
        if picker.version != next { picker.version = next }
        if let cached = WallpaperAppearance.cached(next) {
            FrontendProbe.selected(cached, at: requested)
            publish(cached)
        }
        loading = Task { [weak self] in
            let decoded = await WallpaperAppearance.load(next)
            guard let self, !Task.isCancelled, self.version == next, let decoded else { return }
            FrontendProbe.selected(decoded, at: requested)
            if self.currentImage !== decoded { self.publish(decoded) }
            WallpaperAppearance.preload(startingAt: next, versions: Wallpaper.cycle.map(\.id))
            guard FrontendProbe.report == nil else { return }
            self.icon = Task {
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                guard !Task.isCancelled else { return }
                let version = next
                DispatchQueue.global(qos: .utility).async {
                    UserDefaults.standard.set(version, forKey: "wallpaperVersion")
                }
                guard let icon = await WallpaperAppearance.renderIcon(decoded), !Task.isCancelled else { return }
                WallpaperAppearance.applyIcon(icon, version: next)
            }
        }
    }

    private func publish(_ image: CGImage) {
        let firstImage = currentImage == nil
        currentImage = image
        WallpaperPresentation.select(image)
        // Build image-dependent masks once. Subsequent switches update layers directly.
        if firstImage { objectWillChange.send() }
    }

    func runProbe() async {
        guard FrontendProbe.report != nil else { return }
        // Wait for the same bounded prewarming used by ordinary interaction.
        for _ in 0..<200 {
            if Wallpaper.cycle.allSatisfy({ version in
                guard let image = WallpaperAppearance.cached(version.id) else { return false }
                return WallpaperGPU.shared.cached(image) != nil
            }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        FrontendProbe.beginInteraction()
        for _ in 0..<48 {
            if Task.isCancelled { return }
            next()
            try? await Task.sleep(for: .milliseconds(80))
        }
        await FrontendProbe.exerciseScroll()
        try? await Task.sleep(for: .milliseconds(500))
        FrontendProbe.finish()
    }
}

@MainActor final class WallpaperPickerState: ObservableObject {
    @Published var version = UserDefaults.standard.string(forKey: "wallpaperVersion") ?? "14"
}

struct WallpaperPicker: View {
    @ObservedObject var state: WallpaperPickerState
    let next: () -> Void
    var body: some View {
        let index = Wallpaper.cycle.firstIndex { $0.id == state.version } ?? 0
        Button(action: next) {
            Text(Wallpaper.cycle[index].name)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
                .font(ViewerTypography.font(.semibold, size: 12))
        }
        .help("Switch to \(Wallpaper.cycle[(index + 1) % Wallpaper.cycle.count].title)")
    }
}
