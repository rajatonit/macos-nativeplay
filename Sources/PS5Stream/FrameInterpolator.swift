// 60 -> 120 fps with Apple's machine-learning frame interpolation (VideoToolbox, macOS 26+).
//
// For every new frame from the PS5, the frame halfway between it and the previous one is generated and
// shown first, so the 120 Hz panel gets a new image every refresh. The cost is latency: the real
// frame waits for the interpolation (~9 ms) and then for half a frame period.
//
// The low-latency interpolator only accepts 8-bit 4:2:0. HDR frames are 10-bit, so they're reduced to
// 8 bits with a little noise (dither) first; that turns would-be banding in the in-between frames
// into fine grain that averages out with the untouched 10-bit frames around it.

import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import VideoToolbox

private let ditherSource = """
#include <metal_stdlib>
using namespace metal;
float noise(uint2 p, uint seed) {
    uint h = p.x * 1973u + p.y * 9277u + seed * 26699u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return float(h & 0xffffu) / 65535.0 - 0.5;
}
// 10-bit (MSB-aligned in 16) -> 8-bit, one plane; video-range codes map exactly by dividing by 4.
kernel void dither(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   constant uint &seed [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 v = src.read(gid) * 255.0;
    float4 n = float4(noise(gid, seed), noise(gid, seed + 7u), 0, 0);
    dst.write(clamp(floor(v + 0.5 + n), 0.0, 255.0) / 255.0, gid);
}
"""

final class FrameInterpolator {
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "interpolator", qos: .userInteractive)
    private let commandQueue: MTLCommandQueue
    private let dither: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache!

    private var session: AnyObject?  // VTFrameProcessor (macOS 26+)
    private var size = (0, 0)
    private var inputPool: CVPixelBufferPool?
    private var outputPool: CVPixelBufferPool?
    private var previous: CVPixelBuffer?  // last frame, 8-bit, as fed to the interpolator
    private var frameIndex: Int64 = 0
    private var failed = false

    /// Milliseconds the last interpolation took, for the stats line.
    private(set) var lastMs = 0.0
    private(set) var generated = 0

    /// Attachment marking frames this class made, so the renderer can treat them differently.
    static let generatedKey = "PS5StreamInterpolated" as CFString
    static func isGenerated(_ pb: CVPixelBuffer) -> Bool { CVBufferCopyAttachment(pb, generatedKey, nil) != nil }

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return VTLowLatencyFrameInterpolationConfiguration.isSupported }
        return false
    }

    init?(device: MTLDevice) {
        guard Self.isSupported, let cq = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: ditherSource, options: nil),
              let fn = lib.makeFunction(name: "dither"),
              let p = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.device = device
        commandQueue = cq
        dither = p
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Takes each decoded frame; calls `emit` with the in-between frame (when there is one) and then
    /// the frame itself. `emit` runs on the interpolator's queue.
    func push(_ frame: CVPixelBuffer, emit: @escaping (CVPixelBuffer) -> Void) {
        queue.async { [self] in
            if #available(macOS 26.0, *), !failed, let mid = interpolate(frame) { emit(mid) }
            emit(frame)
        }
    }

    /// Forget the previous frame (after a pause, a seek or switching the feature off).
    func reset() { queue.async { self.previous = nil } }

    @available(macOS 26.0, *)
    private func interpolate(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        if size != (w, h) || session == nil {
            guard start(w, h) else { failed = true; return nil }
        }
        guard let processor = session as? VTFrameProcessor, let input = to8bit(frame) else { return nil }
        defer { previous = input }
        guard let prev = previous, let pool = outputPool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }

        frameIndex += 2
        func ts(_ v: Int64) -> CMTime { CMTime(value: v, timescale: 120) }
        guard let prevFrame = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: ts(frameIndex - 2)),
              let srcFrame = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: ts(frameIndex)),
              let dstFrame = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: ts(frameIndex - 1)),
              let params = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: srcFrame, previousFrame: prevFrame, interpolationPhase: [0.5], destinationFrames: [dstFrame])
        else { return nil }

        let t0 = CACurrentMediaTime()
        let done = DispatchSemaphore(value: 0)
        var error: Error?
        processor.process(parameters: params) { _, e in error = e; done.signal() }
        done.wait()
        lastMs = (CACurrentMediaTime() - t0) * 1000
        if let error {
            print("interpolation: failed (\(error)); showing 60 fps")
            failed = true
            return nil
        }
        // Same colour description as the source, so the renderer treats it as PQ/BT.2020 when HDR.
        CVBufferPropagateAttachments(frame, out)
        CVBufferSetAttachment(out, FrameInterpolator.generatedKey, kCFBooleanTrue, .shouldNotPropagate)
        generated += 1
        return out
    }

    @available(macOS 26.0, *)
    private func start(_ w: Int, _ h: Int) -> Bool {
        (session as? VTFrameProcessor)?.endSession()
        session = nil
        previous = nil
        size = (w, h)
        guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: 1) else {
            print("interpolation: \(w)x\(h) not supported")
            return false
        }
        let processor = VTFrameProcessor()
        do { try processor.startSession(configuration: cfg) } catch {
            print("interpolation: could not start (\(error))")
            return false
        }
        func pool(_ attrs: [String: Any]) -> CVPixelBufferPool? {
            var a = attrs
            a[kCVPixelBufferMetalCompatibilityKey as String] = true
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &p)
            return p
        }
        inputPool = pool(cfg.sourcePixelBufferAttributes)
        outputPool = pool(cfg.destinationPixelBufferAttributes)
        session = processor
        print("interpolation: on, \(w)x\(h) 60 -> 120 fps")
        return inputPool != nil && outputPool != nil
    }

    /// 8-bit frames pass straight through; 10-bit ones are dithered down on the GPU.
    private func to8bit(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        let fmt = CVPixelBufferGetPixelFormatType(frame)
        if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { return frame }
        guard fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, let pool = inputPool else { return nil }
        var dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
        guard let dst, let cb = commandQueue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        var refs: [CVMetalTexture] = []
        func tex(_ pb: CVPixelBuffer, _ plane: Int, _ format: MTLPixelFormat) -> MTLTexture? {
            var ref: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format,
                CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane), plane, &ref)
            guard let ref else { return nil }
            refs.append(ref)
            return CVMetalTextureGetTexture(ref)
        }
        enc.setComputePipelineState(dither)
        var seed = UInt32(truncatingIfNeeded: frameIndex)
        enc.setBytes(&seed, length: 4, index: 0)
        for (plane, f16, f8) in [(0, MTLPixelFormat.r16Unorm, MTLPixelFormat.r8Unorm), (1, .rg16Unorm, .rg8Unorm)] {
            guard let s = tex(frame, plane, f16), let d = tex(dst, plane, f8) else { enc.endEncoding(); return nil }
            enc.setTexture(s, index: 0)
            enc.setTexture(d, index: 1)
            enc.dispatchThreads(MTLSize(width: d.width, height: d.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        _ = refs
        return dst
    }
}
