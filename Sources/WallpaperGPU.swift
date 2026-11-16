import AppKit
import Metal
import MetalKit
import QuartzCore
import SwiftUI

/// Immutable GPU resources are shared by every wallpaper crop in the window.
final class WallpaperGPU {
    static let shared = WallpaperGPU()
    private let preparation = DispatchQueue(label: "vmlab.wallpaper.gpu-resources", qos: .userInitiated)
    private var device: MTLDevice?
    private var commands: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var initialized = false
    private let textures = NSCache<CGImage, Texture>()

    final class Texture {
        let image: CGImage
        let value: MTLTexture
        let commands: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        init(image: CGImage, value: MTLTexture, commands: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
            self.image = image
            self.value = value
            self.commands = commands
            self.pipeline = pipeline
        }
    }

    private init() { textures.totalCostLimit = 160 * 1024 * 1024 }

    func cached(_ image: CGImage) -> Texture? { textures.object(forKey: image) }

    func prepare(_ image: CGImage, completion: @escaping (Texture?) -> Void) {
        preparation.async {
            if let cached = self.textures.object(forKey: image) { completion(cached); return }
            if !self.initialized {
                self.initialized = true
                do {
                    guard let device = MTLCreateSystemDefaultDevice(),
                          let libraryURL = Bundle.main.url(forResource: "Wallpaper", withExtension: "metallib"),
                          let commands = device.makeCommandQueue() else { completion(nil); return }
                    let library = try device.makeLibrary(URL: libraryURL)
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name: "wallpaperVertex")
                    descriptor.fragmentFunction = library.makeFunction(name: "wallpaperFragment")
                    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                    self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                    self.commands = commands
                    self.device = device
                } catch { NSLog("Wallpaper Metal initialization failed: %@", error.localizedDescription) }
            }
            guard let device = self.device, let commands = self.commands, let pipeline = self.pipeline,
                  let texture = try? MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
                    .SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                    .textureStorageMode: MTLStorageMode.private.rawValue
                  ]) else { completion(nil); return }
            let resource = Texture(image: image, value: texture, commands: commands, pipeline: pipeline)
            self.textures.setObject(resource, forKey: image, cost: texture.width * texture.height * 4)
            completion(resource)
        }
    }
}

struct MetalWallpaper: NSViewRepresentable {
    let image: CGImage
    let canvas: CGSize
    let region: CGRect
    let dither: Bool
    let scale: CGFloat
    var primary = false

    func makeNSView(context: Context) -> WallpaperLayerView { WallpaperLayerView() }
    func updateNSView(_ view: WallpaperLayerView, context: Context) {
        view.update(image: WallpaperPresentation.currentImage ?? image, canvas: canvas, region: region, dither: dither, scale: scale, primary: primary)
    }
}

final class WallpaperLayerView: NSView {
    private let rendering = DispatchQueue(label: "vmlab.wallpaper.surface", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pending: Request?
    private var scheduled = false
    private var generation = 0
    private var image: CGImage?
    private var resource: WallpaperGPU.Texture?
    private var previous: Geometry?
    private var laidOutSize = CGSize.zero
    private var visibilityObservers: [NSObjectProtocol] = []
    private let presentationLayer = CAMetalLayer()
    private var metal: CAMetalLayer { presentationLayer }

    private struct Geometry: Equatable {
        let canvas: CGSize
        let region: CGRect
        let dither: Bool
        let scale: CGFloat
        let primary: Bool
    }
    private struct Request {
        let resource: WallpaperGPU.Texture
        let geometry: Geometry
        let selectionTime: Double?
    }
    private struct Uniforms {
        var canvas: SIMD2<Float>
        var origin: SIMD2<Float>
        var region: SIMD2<Float>
        var image: SIMD2<Float>
        var scale: Float
        var dither: UInt32
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        WallpaperPresentation.surfaces.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer {
        let layer = presentationLayer
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = false
        layer.presentsWithTransaction = false
        layer.allowsNextDrawableTimeout = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return layer
    }
    deinit { visibilityObservers.forEach(NotificationCenter.default.removeObserver) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibilityObservers.forEach(NotificationCenter.default.removeObserver)
        visibilityObservers.removeAll()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.redrawAfterLayout()
            })
        }
        DispatchQueue.main.async { [weak self] in self?.redrawAfterLayout() }
    }
    override func layout() {
        super.layout()
        if laidOutSize != bounds.size {
            laidOutSize = bounds.size
            redrawAfterLayout()
        }
    }
    private func redrawAfterLayout() {
        if let resource, let geometry = previous, bounds.width > 0, bounds.height > 0 {
            enqueue(resource, geometry: geometry)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(image: CGImage, canvas: CGSize, region: CGRect, dither: Bool, scale: CGFloat, primary: Bool) {
        let geometry = Geometry(canvas: canvas, region: region, dither: dither, scale: scale, primary: primary)
        guard self.image !== image || previous != geometry else { return }
        previous = geometry
        if primary { FrontendProbe.mark("primary-update region=\(region.size) bounds=\(bounds.size) attached=\(window != nil)") }
        let size = CGSize(width: max(1, region.width * scale), height: max(1, region.height * scale))
        if metal.drawableSize != size { metal.drawableSize = size }
        if metal.contentsScale != scale { metal.contentsScale = scale }
        if self.image === image, let resource { enqueue(resource, geometry: geometry); return }
        self.image = image
        generation += 1
        if let cached = WallpaperGPU.shared.cached(image) {
            resource = cached
            if metal.device == nil { metal.device = cached.value.device }
            enqueue(cached, geometry: geometry)
            return
        }
        let current = generation
        WallpaperGPU.shared.prepare(image) { [weak self] resource in
            DispatchQueue.main.async {
                guard let self, self.generation == current, let geometry = self.previous else { return }
                guard let resource else {
                    self.metal.contents = image
                    self.metal.contentsGravity = .resizeAspectFill
                    return
                }
                self.resource = resource
                if self.metal.device == nil { self.metal.device = resource.value.device }
                self.enqueue(resource, geometry: geometry)
            }
        }
    }

    func select(_ image: CGImage) {
        guard let geometry = previous else { return }
        update(image: image, canvas: geometry.canvas, region: geometry.region,
               dither: geometry.dither, scale: geometry.scale, primary: geometry.primary)
    }

    func setDither(_ enabled: Bool) {
        guard let geometry = previous, let image else { return }
        update(image: image, canvas: geometry.canvas, region: geometry.region,
               dither: enabled, scale: geometry.scale, primary: geometry.primary)
    }

    private func enqueue(_ resource: WallpaperGPU.Texture, geometry: Geometry) {
        guard window?.isVisible == true, bounds.width > 0, bounds.height > 0,
              geometry.region.width > 0, geometry.region.height > 0,
              geometry.canvas.width > 0, geometry.canvas.height > 0 else { return }
        let request = Request(resource: resource, geometry: geometry,
                              selectionTime: FrontendProbe.selectionTime(for: resource.image))
        pendingLock.lock()
        pending = request
        if scheduled { pendingLock.unlock(); return }
        scheduled = true
        pendingLock.unlock()
        rendering.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            pendingLock.lock()
            guard let request = pending else { scheduled = false; pendingLock.unlock(); return }
            pending = nil
            pendingLock.unlock()
            autoreleasepool { draw(request) }
        }
    }

    private func draw(_ request: Request) {
        FrontendProbe.wallpaperRendered()
        // Waiting for a drawable or the GPU never occupies the AppKit thread.
        if request.geometry.primary { FrontendProbe.mark("primary-draw-requested") }
        guard let drawable = metal.nextDrawable(),
              let command = request.resource.commands.makeCommandBuffer() else { return }
        if request.geometry.primary { FrontendProbe.mark("primary-drawable-acquired") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let g = request.geometry
        var uniforms = Uniforms(canvas: SIMD2(Float(g.canvas.width), Float(g.canvas.height)),
                                origin: SIMD2(Float(g.region.minX), Float(g.region.minY)),
                                region: SIMD2(Float(g.region.width), Float(g.region.height)),
                                image: SIMD2(Float(request.resource.value.width), Float(request.resource.value.height)),
                                scale: Float(g.scale), dither: g.dither ? 1 : 0)
        encoder.setRenderPipelineState(request.resource.pipeline)
        encoder.setFragmentTexture(request.resource.value, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if g.primary {
            drawable.addPresentedHandler { drawable in
                FrontendProbe.mark("primary-present-callback")
                FrontendProbe.presented(selection: request.selectionTime, at: drawable.presentedTime)
            }
            command.addCompletedHandler { buffer in
                FrontendProbe.mark("primary-gpu-completed")
                FrontendProbe.gpu(seconds: buffer.gpuEndTime - buffer.gpuStartTime)
            }
        }
        command.present(drawable)
        command.commit()
    }
}

/// Cached wallpaper switches reach the compositor before SwiftUI reconciles labels and layout.
enum WallpaperPresentation {
    static let surfaces = NSHashTable<WallpaperLayerView>.weakObjects()
    private(set) static var currentImage: CGImage?
    static func select(_ image: CGImage) {
        currentImage = image
        surfaces.allObjects.forEach { $0.select(image) }
    }
    static func dither(_ enabled: Bool) { surfaces.allObjects.forEach { $0.setDither(enabled) } }
}
