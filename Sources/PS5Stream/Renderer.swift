// Renders decoded video frames: YCbCr -> RGB (still gamma/PQ encoded) -> MetalFX upscale -> display.
// The layer's colour space tells macOS how to interpret the result (sRGB for SDR, BT.2100 PQ for HDR),
// so the system does the final mapping to the XDR panel.
//
// Highlight boost (HDR only, H toggles): the PS5 grades for the display it thinks it has, which keeps
// highlights around 400 nits. The XDR panel holds 1000, so everything above a 200-nit knee is
// stretched up to 1000 nits. Below the knee (faces, shadows, mid-tones) nothing changes, the curve
// joins smoothly at the knee, and R, G, B are scaled together so colours keep their hue.

import AppKit
import CoreVideo
import Metal
import MetalFX
import MetalPerformanceShaders
import QuartzCore
import simd

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
struct Uniforms { float3x3 m; float3 offset; float4 boost; };  // boost: knee, source peak, target peak, on

constant float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
float3 pqToNits(float3 e) {
    float3 p = pow(max(e, 0.0), 1.0 / m2);
    return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
}
float3 nitsToPQ(float3 n) {
    float3 y = pow(clamp(n / 10000.0, 0.0, 1.0), m1);
    return pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
}
// Identity up to the knee, then a C1-continuous quadratic that sends the source peak to the target.
float expand(float x, float4 b) {
    float knee = b.x, src = b.y, dst = b.z;
    if (x <= knee) return x;
    if (x >= src) return dst + (x - src);
    float a = (src - knee) / (dst - knee);  // slope 1 at the knee
    float t = (x - knee) / (src - knee);
    return knee + (dst - knee) * (a * t + (1.0 - a) * t * t);
}
vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
fragment float4 fmain(VOut in [[stage_in]],
                      texture2d<float> luma [[texture(0)]],
                      texture2d<float> chroma [[texture(1)]],
                      constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 ycc = float3(luma.sample(s, in.uv).r, chroma.sample(s, in.uv).rg) - u.offset;
    float3 rgb = saturate(u.m * ycc);
    if (u.boost.w > 0.5) {
        float3 lin = pqToNits(rgb);
        float peak = max(lin.r, max(lin.g, lin.b));
        if (peak > u.boost.x) rgb = nitsToPQ(lin * (expand(peak, u.boost) / peak));
    }
    return float4(rgb, 1.0);
}
"""

private struct Uniforms {
    var m: simd_float3x3
    var offset: simd_float3
    var boost = simd_float4(0, 0, 0, 0)
}

final class RenderView: NSView {
    var onKey: ((UInt16, Bool) -> Void)?
    /// How 1080p becomes the panel's resolution (U cycles). Neural modes run FSRCNNX on luma for a
    /// sharp 2x frame, then Lanczos-downscale it to the window; MetalFX/bilinear upscale directly.
    enum Upscale: String, CaseIterable { case neuralHQ = "Neural HQ", neuralFast = "Neural fast", metalFX = "MetalFX", bilinear }
    private(set) var upscale: Upscale = .neuralHQ
    private var useMetalFX: Bool { upscale != .bilinear }
    private lazy var neuralHQ = NeuralUpscaler(device: device, network: fsrcnnxHQ)
    private lazy var neuralFast = NeuralUpscaler(device: device, network: fsrcnnxFast)
    private var lumaOutTexture: MTLTexture?  // neural 2x luma, resized to the window
    /// Stretch HDR highlights to the panel's sustained 1000 nits (H toggles).
    private(set) var highlightBoost = true
    /// Brightest the source has been recently (nits), from the decoder. The curve maps this to 1000.
    var sourcePeakNits: Double = 400
    private let boostKnee: Float = 200, boostTarget: Float = 1000

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private let metalLayer = CAMetalLayer()
    private var textureCache: CVMetalTextureCache!
    private var pipeline: MTLRenderPipelineState!
    private var scaler: MTLFXSpatialScaler?
    private lazy var bilinear = MPSImageBilinearScale(device: device)
    // Downscaling (e.g. a 4K stream into a 3024-wide window) needs a proper filter; bilinear aliases.
    private lazy var lanczos = MPSImageLanczosScale(device: device)
    private var rgbTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var link: CADisplayLink?
    private var layerIsHDR: Bool?
    private var warnedFormat = false

    private let lock = NSLock()
    /// Decoded frames waiting for a screen refresh. Wi-Fi delivers frames in bursts, so keeping only
    /// the newest one threw away the first of every pair; a short queue shows both on successive
    /// refreshes instead. Capped so a slow display can't build up latency.
    private var pending: [CVPixelBuffer] = []
    private let maxQueued = 2

    /// 60 -> 120 fps with Apple's frame interpolation (I toggles, remembered).
    private lazy var interpolator = FrameInterpolator(device: device)
    private var interpolationWanted: Bool = {
        (UserDefaults.standard.object(forKey: "interpolate") as? Bool ?? true) && FrameInterpolator.isSupported
    }()
    /// Interpolation actually running: wanted, and only in Max (it's the biggest GPU cost by far).
    var interpolating: Bool { interpolationWanted && power == .max }
    private var wasInterpolating = false

    // MARK: - Power

    /// How hard the GPU works (E cycles, remembered). The Mac also steps down on its own when macOS
    /// reports it's getting hot, and goes to Cool in Low Power Mode.
    /// GPU work per frame on the M5 Pro at full clock (busy % is misleading: the GPU clocks down):
    ///   Max:      120 fps interpolation + Neural HQ on real frames; interpolation (~9 ms a frame) dominates
    ///   Balanced: Neural HQ, 60 fps (~5.5 ms per frame)
    ///   Cool:     Neural fast, 60 fps (~3 ms per frame)
    enum Power: Int, CaseIterable, Comparable {
        case cool, balanced, max
        static func < (a: Power, b: Power) -> Bool { a.rawValue < b.rawValue }
        var name: String { ["Cool", "Balanced", "Max"][rawValue] }
    }
    private var powerChoice: Power = Power(rawValue: UserDefaults.standard.object(forKey: "power") as? Int ?? Power.balanced.rawValue) ?? .balanced
    /// What heat and Low Power Mode currently allow.
    private var powerCap: Power {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .cool }
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return .cool
        case .serious: return .balanced
        default: return .max
        }
    }
    var power: Power { min(powerChoice, powerCap) }
    private var loggedPower: Power?
    private var received = 0
    private var dropped = 0

    private var presented = 0
    private var gpuMsSum = 0.0
    private var lastStats = CACurrentMediaTime()
    var extraStats: (() -> String)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        let lib = try! device.makeLibrary(source: shaderSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "vmain")
        pd.fragmentFunction = lib.makeFunction(name: "fmain")
        pd.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try! device.makeRenderPipelineState(descriptor: pd)

        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.framebufferOnly = false  // we blit into the drawable
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Cursor

    /// Transparent cursor shown over the video in full screen, so the pointer never sits on the game.
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    private var fullScreenObservers: [NSObjectProtocol] = []

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    override func resetCursorRects() {
        if isFullScreen { addCursorRect(bounds, cursor: Self.blankCursor) }
    }

    private func fullScreenChanged() {
        window?.invalidateCursorRects(for: self)
        if isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }  // takes effect without waiting for a move
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullScreenObservers = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                self?.fullScreenChanged()
            }
        }
        guard window != nil, link == nil else { return }
        link = displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        switch event.charactersIgnoringModifiers {
        case "u":
            let all = Upscale.allCases
            upscale = all[(all.firstIndex(of: upscale)! + 1) % all.count]
            print("render: upscaling with \(upscale.rawValue)")
        case "i":
            guard FrameInterpolator.isSupported else { print("render: frame interpolation needs macOS 26"); break }
            interpolationWanted.toggle()
            UserDefaults.standard.set(interpolationWanted, forKey: "interpolate")
            print("render: 120 fps interpolation \(interpolationWanted ? "on" : "off")")
        case "e":
            let all = Power.allCases
            powerChoice = all[(all.firstIndex(of: powerChoice)! + 1) % all.count]
            UserDefaults.standard.set(powerChoice.rawValue, forKey: "power")
            print("render: power mode \(powerChoice.name)" + (power != powerChoice ? " (limited to \(power.name) by heat or Low Power Mode)" : ""))
        case "h": highlightBoost.toggle(); print("render: highlight boost \(highlightBoost ? "on" : "off")")
        case "q" where event.modifierFlags.contains(.command): NSApp.terminate(nil)
        default: onKey?(event.keyCode, true)
        }
    }

    override func keyUp(with event: NSEvent) { onKey?(event.keyCode, false) }

    /// Called from the decoder thread. With 120 fps on, frames go through the interpolator first.
    func submit(_ pixelBuffer: CVPixelBuffer) {
        let on = interpolating
        if on != wasInterpolating {
            wasInterpolating = on
            interpolator?.reset()  // don't blend with a frame from before the pause
        }
        if on, let ip = interpolator {
            ip.push(pixelBuffer) { [weak self] in self?.enqueue($0) }
        } else {
            enqueue(pixelBuffer)
        }
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        pending.append(pixelBuffer)
        // Interpolation delivers frames in pairs (in-between + real), so allow room for a Wi-Fi burst of two pairs.
        if pending.count > maxQueued + (interpolating ? 2 : 0) {
            pending.removeFirst()
            dropped += 1
        }
        received += 1
        lock.unlock()
    }

    // MARK: - Frame description

    private struct FrameInfo {
        var lumaFormat: MTLPixelFormat
        var chromaFormat: MTLPixelFormat
        var uniforms: Uniforms
        var hdr: Bool
    }

    private func describe(_ pb: CVPixelBuffer) -> FrameInfo? {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let bits: Int, full: Bool
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: (bits, full) = (8, false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: (bits, full) = (8, true)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: (bits, full) = (10, false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: (bits, full) = (10, true)
        default: return nil
        }
        func attachment(_ key: CFString) -> String? {
            CVBufferCopyAttachment(pb, key, nil) as? String
        }
        let transfer = attachment(kCVImageBufferTransferFunctionKey)
        let matrix = attachment(kCVImageBufferYCbCrMatrixKey)
        let hdr = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        let is2020 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) || (matrix == nil && hdr)
        let is601 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        let (kr, kb): (Float, Float) = is2020 ? (0.2627, 0.0593) : is601 ? (0.299, 0.114) : (0.2126, 0.0722)
        let kg = 1 - kr - kb

        let maxV = Float((1 << bits) - 1), unit = Float(1 << (bits - 8))
        let yOff = full ? 0 : 16 * unit / maxV
        let cOff = 128 * unit / maxV
        let sy = full ? 1 : maxV / (219 * unit)
        let sc = full ? 1 : maxV / (224 * unit)
        let m = simd_float3x3(columns: (
            simd_float3(sy, sy, sy),
            simd_float3(0, -2 * (1 - kb) * kb / kg, 2 * (1 - kb)) * sc,
            simd_float3(2 * (1 - kr), -2 * (1 - kr) * kr / kg, 0) * sc))
        return FrameInfo(
            lumaFormat: bits == 8 ? .r8Unorm : .r16Unorm,
            chromaFormat: bits == 8 ? .rg8Unorm : .rg16Unorm,
            uniforms: Uniforms(m: m, offset: simd_float3(yOff, cOff, cOff)),
            hdr: hdr)
    }

    private func configureLayer(hdr: Bool) {
        guard layerIsHDR != hdr else { return }
        layerIsHDR = hdr
        metalLayer.wantsExtendedDynamicRangeContent = hdr
        if hdr {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            metalLayer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 203)
        } else {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metalLayer.edrMetadata = nil
        }
    }

    // MARK: - Sizing

    /// Largest size with the source's aspect ratio that fits the view, in device pixels.
    private func targetSize(srcW: Int, srcH: Int) -> (Int, Int) {
        let scale = window?.backingScaleFactor ?? 2
        let vw = bounds.width * scale, vh = bounds.height * scale
        let s = min(vw / CGFloat(srcW), vh / CGFloat(srcH))
        return (max(2, Int(CGFloat(srcW) * s) & ~1), max(2, Int(CGFloat(srcH) * s) & ~1))
    }

    private func makeTexture(_ w: Int, _ h: Int) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead, .shaderWrite]
        td.storageMode = .private
        return device.makeTexture(descriptor: td)
    }

    private func prepare(srcW: Int, srcH: Int, outW: Int, outH: Int) {
        if rgbTexture?.width != srcW || rgbTexture?.height != srcH {
            rgbTexture = makeTexture(srcW, srcH)
            outputTexture = nil
        }
        if outputTexture?.width == outW, outputTexture?.height == outH { return }
        outputTexture = makeTexture(outW, outH)
        metalLayer.drawableSize = CGSize(width: outW, height: outH)

        scaler = nil
        // MetalFX spatial only upscales; when the window is smaller than the source we use bilinear.
        if outW >= srcW, outH >= srcH {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = srcW
            d.inputHeight = srcH
            d.outputWidth = outW
            d.outputHeight = outH
            d.colorTextureFormat = .rgba16Float
            d.outputTextureFormat = .rgba16Float
            d.colorProcessingMode = .perceptual  // input is gamma- or PQ-encoded, 0...1
            scaler = d.makeSpatialScaler(device: device)
        }
    }

    // MARK: - Drawing

    private var loggedDisplay = false
    /// Diagnostics for --verbose: display-link ticks, frames taken, drawables refused.
    private(set) var ticks = 0, taken = 0, noDrawable = 0

    @objc private func tick(_ link: CADisplayLink) {
        if !loggedDisplay, let screen = window?.screen {
            loggedDisplay = true
            let hz = 1 / max(link.targetTimestamp - link.timestamp, 0.001)
            print(String(format: "display: %@ | link %.0f Hz (screen max %ld Hz) | EDR headroom now %.1fx, potential %.1fx, reference %.1fx | backing scale %.0f",
                         screen.localizedName, hz, screen.maximumFramesPerSecond,
                         screen.maximumExtendedDynamicRangeColorComponentValue,
                         screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                         screen.maximumReferenceExtendedDynamicRangeColorComponentValue,
                         window?.backingScaleFactor ?? 0))
        }
        ticks += 1
        lock.lock()
        let pb = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        guard let pb else { return }
        taken += 1
        guard let info = describe(pb) else {
            if !warnedFormat {
                warnedFormat = true
                print("render: unsupported pixel format \(CVPixelBufferGetPixelFormatType(pb))")
            }
            return
        }

        let srcW = CVPixelBufferGetWidth(pb), srcH = CVPixelBufferGetHeight(pb)
        var lumaRef: CVMetalTexture?, chromaRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, nil, info.lumaFormat, srcW, srcH, 0, &lumaRef)
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, nil, info.chromaFormat, srcW / 2, srcH / 2, 1, &chromaRef)
        guard let lumaRef, let chromaRef,
              let luma = CVMetalTextureGetTexture(lumaRef),
              let chroma = CVMetalTextureGetTexture(chromaRef)
        else { return }

        configureLayer(hdr: info.hdr)
        let (outW, outH) = targetSize(srcW: srcW, srcH: srcH)
        prepare(srcW: srcW, srcH: srcH, outW: outW, outH: outH)
        guard let rgb = rgbTexture, let out = outputTexture else { return }
        guard let drawable = metalLayer.nextDrawable(), let cb = queue.makeCommandBuffer() else {
            noDrawable += 1
            // No free drawable this refresh: keep the frame for the next one instead of losing it.
            lock.lock()
            pending.insert(pb, at: 0)
            lock.unlock()
            return
        }

        // Neural path: FSRCNNX doubles the luma, Lanczos fits that single channel to the window, then the
        // colour conversion (and highlight boost) runs once, straight into the output at window size.
        // Only used when the window is bigger than the source.
        var lumaIn = luma, target = rgb, neural = false
        // HQ (~6 ms) can't run 120 times a second: with interpolation on, real PS5 frames get HQ and
        // the generated in-between frames get the fast network.
        let useHQ = upscale == .neuralHQ && power >= .balanced && !(interpolating && FrameInterpolator.isGenerated(pb))
        let net = useHQ ? neuralHQ : upscale == .neuralHQ || upscale == .neuralFast ? neuralFast : nil
        if let net, outW > srcW, let luma2x = net.encode(cb, luma: luma) {
            if lumaOutTexture?.width != outW || lumaOutTexture?.height != outH {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: outW, height: outH, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                lumaOutTexture = device.makeTexture(descriptor: d)
            }
            if let lumaOut = lumaOutTexture {
                // 2x is 3840 wide; windows narrower than that get Lanczos, wider ones bilinear.
                if outW <= luma2x.width { lanczos.encode(commandBuffer: cb, sourceTexture: luma2x, destinationTexture: lumaOut) }
                else { bilinear.encode(commandBuffer: cb, sourceTexture: luma2x, destinationTexture: lumaOut) }
                lumaIn = lumaOut; target = out; neural = true
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = info.uniforms
        // Only boost when there's real headroom between the source peak and the panel.
        let srcPeak = Float(min(max(sourcePeakNits, 300), 800))
        let boosting = info.hdr && highlightBoost
        if boosting { uniforms.boost = simd_float4(boostKnee, srcPeak, boostTarget, 1) }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(lumaIn, index: 0)
        enc.setFragmentTexture(chroma, index: 1)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        let fx = useMetalFX && !neural ? scaler : nil
        if neural {
            // already rendered into `out`
        } else if let fx {
            fx.colorTexture = rgb
            fx.outputTexture = out
            fx.encode(commandBuffer: cb)
        } else if !useMetalFX || scaler != nil {
            bilinear.encode(commandBuffer: cb, sourceTexture: rgb, destinationTexture: out)
        } else {
            lanczos.encode(commandBuffer: cb, sourceTexture: rgb, destinationTexture: out)
        }
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: out, to: drawable.texture)
            blit.endEncoding()
        }
        cb.present(drawable)
        let p = power
        if p != loggedPower {
            loggedPower = p
            print("render: power \(p.name)" + (p != powerChoice ? " (stepped down from \(powerChoice.name): \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power Mode" : "Mac is hot"))" : ""))
        }
        let netName = upscale == .neuralHQ && p >= .balanced ? (interpolating ? "Neural HQ + fast in-between" : "Neural HQ") : "Neural fast"
        let mode = p.name + " | " + (interpolating ? String(format: "120 fps (interp %.1f ms) ", interpolator?.lastMs ?? 0) : "")
            + (neural ? netName : fx != nil ? "MetalFX" : scaler == nil && useMetalFX ? "Lanczos" : "bilinear") + (info.hdr ? " HDR" : " SDR")
            + (boosting ? String(format: " boost %.0f->%.0f nits", srcPeak, boostTarget) : "")
        cb.addCompletedHandler { [weak self] cb in
            _ = (lumaRef, chromaRef, pb)  // keep the source frame alive until the GPU is done with it
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            DispatchQueue.main.async {
                self?.record(gpuMs: ms, mode: mode, src: (srcW, srcH), out: (outW, outH))
            }
        }
        cb.commit()
    }

    private func record(gpuMs: Double, mode: String, src: (Int, Int), out: (Int, Int)) {
        presented += 1
        gpuMsSum += gpuMs
        let now = CACurrentMediaTime()
        let dt = now - lastStats
        guard dt >= 1 else { return }
        let clock = String(Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()))
        lock.lock()
        let got = received, skipped = dropped
        received = 0
        dropped = 0
        lock.unlock()
        var line = clock + " " + String(
            format: "%@ | %dx%d -> %dx%d | in %.0f fps, shown %.0f fps, skipped %d | GPU %.2f ms",
            mode, src.0, src.1, out.0, out.1,
            Double(got) / dt, Double(presented) / dt, skipped, gpuMsSum / Double(presented))
        if let extra = extraStats?(), !extra.isEmpty { line += " | " + extra }
        window?.title = line
        print(line)
        presented = 0
        gpuMsSum = 0
        lastStats = now
    }
}
