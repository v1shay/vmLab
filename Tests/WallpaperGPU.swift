import AppKit
import Metal
import MetalKit

@main enum WallpaperTest {
    struct Uniforms {
        var canvas: SIMD2<Float> = SIMD2(64, 64)
        var origin: SIMD2<Float> = .zero
        var region: SIMD2<Float> = SIMD2(64, 64)
        var image: SIMD2<Float> = SIMD2(8, 8)
        var scale: Float = 1
        var dither: UInt32 = 0
    }
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal device unavailable")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "wallpaperVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "wallpaperFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        func render(gray: Bool, dither: Bool, crop: Bool = false) throws -> [UInt8] {
            var pixels = [UInt8](repeating: 255, count: 8 * 8 * 4)
            for y in 0..<8 {
                for x in 0..<8 {
                    let offset = (y * 8 + x) * 4
                    let color: [UInt8] = gray ? [128,128,128] :
                        y < 4 ? (x < 4 ? [255,0,0] : [0,255,0]) : (x < 4 ? [0,0,255] : [255,255,0])
                    pixels.replaceSubrange(offset..<(offset + 3), with: color)
                }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let input = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false])
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            outputDescriptor.storageMode = .shared
            outputDescriptor.usage = .renderTarget
            let output = device.makeTexture(descriptor: outputDescriptor)!
            let command = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            var uniforms = Uniforms()
            uniforms.dither = dither ? 1 : 0
            if crop { uniforms.origin = SIMD2(32,0); uniforms.region = SIMD2(32,64) }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(input, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed)
            var result = [UInt8](repeating: 0, count: 64*64*4)
            output.getBytes(&result, bytesPerRow: 256, from: MTLRegionMake2D(0,0,64,64), mipmapLevel: 0)
            return result
        }
        func rgb(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * 64 + x) * 4
            return [bytes[offset+2],bytes[offset+1],bytes[offset]]
        }
        let normal = try render(gray: false, dither: false)
        precondition(rgb(normal, 4, 4) == [255,0,0], "Top-left orientation")
        precondition(rgb(normal, 59, 4) == [0,255,0], "Top-right orientation")
        precondition(rgb(normal, 4, 59) == [0,0,255], "Bottom-left orientation")
        let cropped = try render(gray: false, dither: false, crop: true)
        precondition(rgb(cropped, 59, 4) == [0,255,0], "Canvas-aligned slice")
        let dots = try render(gray: true, dither: true)
        precondition(rgb(dots,0,0) == [128,128,128], "Undithered pixel")
        precondition(rgb(dots,1,1).allSatisfy { (38...41).contains($0) }, "GPU Bayer dot")
        print("PASS: actual Metal shader orientation, canvas-aligned cropping, and GPU dithering")
    }
}
