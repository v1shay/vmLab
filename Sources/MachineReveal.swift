import AppKit
import CoreText
import QuartzCore
import SwiftUI

enum TaskRuntime: String {
    case process, docker, kubernetes

    static func detect(_ command: [String]) -> Self {
        guard let executable = command.first else { return .process }
        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "docker": return .docker
        case "kubectl", "helm", "kind", "k3s", "kubeadm": return .kubernetes
        default: return .process
        }
    }
    var title: String {
        switch self {
        case .docker: return "Docker"
        case .kubernetes: return "Kubernetes"
        case .process: return "Process"
        }
    }
}

enum MachineSymbol: Equatable {
    case os(GuestOS)
    case system(String)
    case runtime(TaskRuntime)

    var resource: String? {
        switch self {
        case .os(.linux): return "Linux.gif"
        case .runtime(.docker): return "Docker.png"
        case .runtime(.kubernetes): return "Kubernetes.png"
        default: return nil
        }
    }
    var systemName: String {
        switch self {
        case .os(.macOS): return "apple.logo"
        case .os: return "desktopcomputer"
        case let .system(name): return name
        case .runtime: return "gearshape.2.fill"
        }
    }
}

/// The render server plays precomputed glyph frames. Scrolling never runs a text timer.
struct MachineReveal: NSViewRepresentable {
    let id: String
    let name: String
    let symbol: MachineSymbol
    var online = true
    var order = 0
    @Environment(\.viewerControlScale) private var controlScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> MachineRevealView { MachineRevealView() }
    func updateNSView(_ view: MachineRevealView, context: Context) {
        view.update(id: id, name: name, symbol: symbol, size: 13 * controlScale,
                    color: online ? .white : NSColor(white: 0.66, alpha: 1),
                    scale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
                    order: order, reducedMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: MachineRevealView, coordinator: ()) { view.cancel() }
}

final class MachineRevealView: NSView {
    private let text = CALayer()
    private let icon = CALayer()
    private var key = ""
    private var generation = 0
    private var ticket = RevealTicket()
    private var pointSize: CGFloat = 13
    private var nameWidth: CGFloat = 120
    private var scale: CGFloat = 2
    private static var revealed = Set<String>()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        for item in [text, icon] {
            item.contentsGravity = .left
            item.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(item)
        }
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: nameWidth + 32, height: max(24, pointSize * 2)) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = CGRect(x: 0, y: (bounds.height - 24) / 2, width: 24, height: 24)
        text.frame = CGRect(x: 32, y: 0, width: max(0, bounds.width - 32), height: bounds.height)
        CATransaction.commit()
    }
    func cancel() { ticket.cancel(); generation += 1; layer?.removeAllAnimations(); text.removeAllAnimations(); icon.removeAllAnimations() }

    func update(id: String, name: String, symbol: MachineSymbol, size: CGFloat,
                color: NSColor, scale: CGFloat, order: Int, reducedMotion: Bool) {
        let nextKey = "\(id)|\(name)|\(symbol)|\(size)|\(color)|\(scale)|\(reducedMotion)"
        guard key != nextKey else { return }
        key = nextKey
        ticket.cancel()
        ticket = RevealTicket()
        generation += 1
        let current = generation
        pointSize = size
        nameWidth = CGFloat(name.count) * size * 0.64
        invalidateIntrinsicContentSize()
        text.removeAllAnimations()
        icon.removeAllAnimations()
        layer?.removeAllAnimations()
        self.scale = scale
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
        let identity = id + "|" + name
        let animate = !reducedMotion && !Self.revealed.contains(identity)
        // Mark once for this session so virtualized rows never replay during scrolling.
        Self.revealed.insert(identity)
        let fontName = ViewerTypography.nativeFontName
        RevealFrames.prepare(name: name, symbol: symbol, size: size, color: color,
                             scale: scale, fontName: fontName, animated: animate, ticket: ticket) { [weak self] frames in
            DispatchQueue.main.async {
                guard let self, self.generation == current, let frames else { return }
                self.text.contentsScale = scale
                self.icon.contentsScale = scale
                self.text.contents = frames.text.last
                self.icon.contents = frames.icon.last
                self.needsLayout = true
                guard animate, self.window != nil else { return }
                FrontendProbe.revealPlayed()
                let delay = Double(min(order, 7)) * 0.018
                let begin = CACurrentMediaTime() + delay
                for (target, values) in [(self.text, frames.text), (self.icon, frames.icon)] {
                    let animation = CAKeyframeAnimation(keyPath: "contents")
                    animation.values = values
                    animation.calculationMode = .discrete
                    animation.duration = 0.28
                    animation.beginTime = begin
                    animation.fillMode = .backwards
                    target.add(animation, forKey: "reveal")
                }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.20
                fade.beginTime = begin
                fade.fillMode = .backwards
                self.layer?.add(fade, forKey: "arrival")
                let movement = CABasicAnimation(keyPath: "transform.translation.y")
                movement.fromValue = -4
                movement.toValue = 0
                movement.duration = 0.24
                movement.beginTime = begin
                movement.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.layer?.add(movement, forKey: "arrival-position")
            }
        }
    }
}

private final class RevealTicket {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

private final class RevealFrames {
    let text: [CGImage]
    let icon: [CGImage]
    init(text: [CGImage], icon: [CGImage]) { self.text = text; self.icon = icon }
    private static let queue = DispatchQueue(label: "vmlab.machine-reveal", qos: .userInitiated)
    private static let cache: NSCache<NSString, RevealFrames> = {
        let result = NSCache<NSString, RevealFrames>()
        result.totalCostLimit = 48 * 1024 * 1024
        return result
    }()

    static func prepare(name: String, symbol: MachineSymbol, size: CGFloat, color: NSColor, scale: CGFloat,
                        fontName: String, animated: Bool, ticket: RevealTicket, completion: @escaping (RevealFrames?) -> Void) {
        let foreground = color.cgColor
        let key = "\(name)|\(symbol)|\(size)|\(color)|\(scale)|\(animated)" as NSString
        queue.async {
            guard !ticket.cancelled else { completion(nil); return }
            if let existing = cache.object(forKey: key) { completion(existing); return }
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            let height = max(24, size * 2)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground
            ]
            let finalLine = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: attributes))
            let width = min(4096, max(1, ceil(CTLineGetTypographicBounds(finalLine, nil, nil, nil)) + 2))
            func raster(_ value: String, width: CGFloat = width, height: CGFloat = height) -> CGImage? {
                guard let context = CGContext(data: nil, width: max(1, Int(width * scale)),
                                              height: max(1, Int(height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.scaleBy(x: scale, y: scale)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                context.textPosition = CGPoint(x: 0, y: (height - ascent - descent) / 2 + descent)
                CTLineDraw(line, context)
                return context.makeImage()
            }
            var textFrames: [CGImage] = []
            var iconFrames: [CGImage] = []
            if animated {
                let glyphs = Array("01#%+<>/\\[]{}=*")
                let characters = Array(name)
                for step in 0..<9 {
                    guard !ticket.cancelled else { completion(nil); return }
                    let resolved = Int(Double(characters.count) * Double(step) / 8)
                    let scrambled = characters.enumerated().map { offset, character -> Character in
                        if offset < resolved || character.isWhitespace { return character }
                        return glyphs[(offset * 7 + step * 11) % glyphs.count]
                    }
                    if let frame = raster(String(scrambled)) { textFrames.append(frame) }
                    if let frame = raster(String(glyphs[(step * 3) % glyphs.count]), width: 24, height: 24) { iconFrames.append(frame) }
                }
            }
            guard let finalText = raster(name),
                  let context = CGContext(data: nil, width: Int(24 * scale), height: Int(24 * scale),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { completion(nil); return }
            context.scaleBy(x: scale, y: scale)
            let image: NSImage?
            if symbol == .runtime(.process) {
                // Generic jobs use the requested paired orchestration marks.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                for (resource, bounds) in [
                    ("Docker.png", CGRect(x: 0, y: 10, width: 17, height: 12)),
                    ("Kubernetes.png", CGRect(x: 10, y: 0, width: 14, height: 14))
                ] {
                    NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent(resource))?.draw(in: bounds)
                }
                NSGraphicsContext.restoreGraphicsState()
                image = nil
            } else if let resource = symbol.resource {
                image = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent(resource))
            } else {
                image = NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [NSColor(cgColor: foreground) ?? .white]))
            }
            if let image {
                let fit = min(24 / image.size.width, 24 / image.size.height)
                let fitted = CGSize(width: image.size.width * fit, height: image.size.height * fit)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                image.draw(in: CGRect(x: (24 - fitted.width) / 2, y: (24 - fitted.height) / 2,
                                      width: fitted.width, height: fitted.height))
                NSGraphicsContext.restoreGraphicsState()
            }
            guard let finalIcon = context.makeImage() else { completion(nil); return }
            FrontendProbe.iconPrepared(symbol.resource, image: finalIcon)
            textFrames.append(finalText)
            iconFrames.append(finalIcon)
            let frames = RevealFrames(text: textFrames, icon: iconFrames)
            let cost = (textFrames + iconFrames).reduce(0) { $0 + $1.bytesPerRow * $1.height }
            cache.setObject(frames, forKey: key, cost: cost)
            completion(frames)
        }
    }
}
