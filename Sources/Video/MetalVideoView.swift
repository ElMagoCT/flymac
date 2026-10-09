import Foundation
import Metal
import MetalKit
import CoreVideo
import SwiftUI
import CoreImage

/// Draws BGRA CVPixelBuffers with Metal. Shaders are compiled at runtime
/// (no Xcode metal compiler needed). Phase 3 monitor tools plug in as extra
/// fragment stages on `MonitorRenderer`.
public final class MetalVideoRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var latest: VideoFrame?
    private let lock = NSLock()
    public var onDisplayed: (@Sendable (VideoFrame) -> Void)?
    /// Uniforms the monitor tools can drive: zebra threshold, peaking, guides…
    public var uniforms = MonitorUniforms()

    public struct MonitorUniforms: Sendable {
        public var zebraOn: Float = 0, zebraLevel: Float = 0.95
        public var peakingOn: Float = 0, peakingThreshold: Float = 0.25
        public var falseColorOn: Float = 0
        public var desqueeze: Float = 1.0
        public var guidesOn: Float = 0
        public var exposureGain: Float = 1.0
        public init() {}
    }

    public static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    struct U { float zebraOn, zebraLevel, peakingOn, peakingThreshold, falseColorOn, desqueeze, guidesOn, gain; };
    vertex VOut vmain(uint vid [[vertex_id]], constant float &aspectFix [[buffer(0)]]) {
        float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        float2 t[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
        VOut o; o.pos = float4(p[vid].x * aspectFix, p[vid].y, 0, 1); o.uv = t[vid]; return o;
    }
    float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant U &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear);
        float3 c = tex.sample(s, in.uv).rgb * u.gain;
        float y = luma(c);
        if (u.falseColorOn > 0.5) {
            float3 fc = y < 0.02 ? float3(0.5,0,0.6) : y < 0.1 ? float3(0,0,1) : y < 0.2 ? float3(0,0.6,1) : y < 0.42 ? float3(0.4,0.4,0.4)
                      : y < 0.5 ? float3(0.2,0.8,0.2) : y < 0.6 ? float3(0.6,0.6,0.6) : y < 0.8 ? float3(0.95,0.85,0.5) : y < 0.95 ? float3(1,0.5,0) : float3(1,0,0);
            c = fc;
        }
        if (u.zebraOn > 0.5 && y > u.zebraLevel) {
            float stripe = fract((in.pos.x + in.pos.y) / 12.0);
            c = stripe < 0.5 ? float3(1,1,1) : float3(0,0,0);
        }
        if (u.peakingOn > 0.5) {
            float2 d = 1.0 / float2(tex.get_width(), tex.get_height());
            float gx = luma(tex.sample(s, in.uv + float2(d.x,0)).rgb) - luma(tex.sample(s, in.uv - float2(d.x,0)).rgb);
            float gy = luma(tex.sample(s, in.uv + float2(0,d.y)).rgb) - luma(tex.sample(s, in.uv - float2(0,d.y)).rgb);
            if (sqrt(gx*gx + gy*gy) > u.peakingThreshold) c = float3(1, 0.2, 0.2);
        }
        if (u.guidesOn > 0.5) {
            float2 g = abs(fract(in.uv * 3.0) - 0.5);
            if (min(g.x, g.y) > 0.495) c = mix(c, float3(1,1,1), 0.6);
        }
        return float4(c, 1);
    }
    """

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let q = device.makeCommandQueue() else { return nil }
        self.device = device; queue = q
        do {
            let lib = try device.makeLibrary(source: MetalVideoRenderer.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch { return nil }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        super.init()
    }

    /// When no MTKView is drawing (headless capture), count frames as displayed on arrival.
    public var countOnSubmit = false

    public func submit(_ frame: VideoFrame) {
        lock.withLock { latest = frame }
        if countOnSubmit { onDisplayed?(frame) }
    }

    /// The most recent picture as a CGImage (for screenshots and stills).
    public func snapshot() -> CGImage? {
        guard let f = lock.withLock({ latest }) else { return nil }
        let ci = CIImage(cvPixelBuffer: f.pixelBuffer)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let frame = lock.withLock({ latest }), let cache = textureCache,
              let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(frame.pixelBuffer), h = CVPixelBufferGetHeight(frame.pixelBuffer)
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, frame.pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }
        // Letterbox: scale x so the picture keeps its aspect ratio (with desqueeze).
        let picAspect = Double(w) / Double(h) * Double(uniforms.desqueeze)
        let viewAspect = view.drawableSize.width / max(1, view.drawableSize.height)
        var aspectFix = Float(picAspect / viewAspect)
        var yFix: Float = 1
        if aspectFix > 1 { yFix = 1 / aspectFix; aspectFix = 1 }
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&aspectFix, length: 4, index: 0)
        var u = uniforms
        enc.setFragmentBytes(&u, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        // Vertical letterbox via viewport.
        let vh = Double(view.drawableSize.height) * Double(yFix)
        enc.setViewport(MTLViewport(originX: 0, originY: (Double(view.drawableSize.height) - vh) / 2, width: Double(view.drawableSize.width), height: vh, znear: 0, zfar: 1))
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        onDisplayed?(frame)
    }
}

/// SwiftUI wrapper.
public struct MetalVideoView: NSViewRepresentable {
    public let renderer: MetalVideoRenderer
    public init(renderer: MetalVideoRenderer) { self.renderer = renderer }

    public func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.delegate = renderer
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 1)
        v.preferredFramesPerSecond = 60
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.layer?.isOpaque = true
        return v
    }
    public func updateNSView(_ nsView: MTKView, context: Context) {}
}
