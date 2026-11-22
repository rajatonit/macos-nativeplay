// "Enhanced look" (L toggles, remembered): a grade on the upscaled frame that makes the picture pop.
//
//   - Clarity: local contrast. The frame's log-luminance is averaged on a 1/8-size grid and blurred,
//     giving the local brightness around each pixel; detail relative to that is amplified. This adds
//     depth to mid-size shapes (buildings, faces, clouds) without sharpening fine compression noise.
//   - Contrast: a gentle global S around mid-grey, with a soft roll-off so highlights don't clip.
//   - Vibrance: more saturation for muted colours, less for already saturated ones (so skies and
//     foliage gain colour, but neon and skin don't go garish).
//   - Split tone: a faint cool cast in shadows and warm cast in highlights.
//
// Luminance is changed by scaling R, G, B together, so hues stay put. It works in linear light: PQ
// (nits) for HDR, sRGB gamma for SDR. This is a grade of the video, not re-rendering: it can't add
// detail or lighting the game didn't draw. Cost is about 1 ms per frame at 3024x1700.

import Metal
import MetalPerformanceShaders

private let lookSource = """
#include <metal_stdlib>
using namespace metal;
constant float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
float3 pqToNits(float3 e) {
    float3 p = pow(max(e, 0.0), 1.0 / m2);
    return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
}
float3 nitsToPQ(float3 n) {
    float3 y = pow(clamp(n / 10000.0, 0.0, 1.0), m1);
    return pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
}
// Linear light in nits (SDR white = 100).
float3 toLinear(float3 e, bool hdr) { return hdr ? pqToNits(e) : pow(saturate(e), 2.2) * 100.0; }
float3 fromLinear(float3 l, bool hdr) { return hdr ? nitsToPQ(l) : pow(saturate(l / 100.0), 1.0 / 2.2); }
float lum(float3 l, bool hdr) {
    return max(dot(l, hdr ? float3(0.2627, 0.6780, 0.0593) : float3(0.2126, 0.7152, 0.0722)), 0.0);
}

struct LookParams { float clarity; float contrast; float vibrance; float tone; uint hdr; };

// 1/8-size log2-luminance grid (4 bilinear taps per cell, so each covers the 8x8 block it stands for).
kernel void lookBase(texture2d<float, access::sample> frame [[texture(0)]],
                     texture2d<float, access::write> base [[texture(1)]],
                     constant LookParams &p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= base.get_width() || gid.y >= base.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 inv = 1.0 / float2(base.get_width(), base.get_height());
    float acc = 0.0;
    for (int j = 0; j < 2; j++) for (int i = 0; i < 2; i++) {
        float2 uv = (float2(gid) + float2(0.25 + 0.5 * i, 0.25 + 0.5 * j)) * inv;
        acc += log2(lum(toLinear(frame.sample(s, uv).rgb, p.hdr != 0), p.hdr != 0) + 0.05);
    }
    base.write(float4(acc * 0.25), gid);
}

kernel void lookApply(texture2d<float, access::read_write> frame [[texture(0)]],
                      texture2d<float, access::sample> base [[texture(1)]],
                      constant LookParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= frame.get_width() || gid.y >= frame.get_height()) return;
    bool hdr = p.hdr != 0;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 l = toLinear(frame.read(gid).rgb, hdr);
    float y = lum(l, hdr);
    float ly = log2(y + 0.05);
    float2 uv = (float2(gid) + 0.5) / float2(frame.get_width(), frame.get_height());
    float local = base.sample(s, uv).r;

    // Clarity, eased off in deep shadows (where it would mostly lift noise) and limited near edges
    // with a big step (which would otherwise halo).
    float detail = clamp(ly - local, -1.2, 1.2);
    float shadowEase = smoothstep(-2.0, 1.0, ly);       // ~0 below 0.25 nits, full above 2 nits
    float nl = ly + p.clarity * shadowEase * detail * (1.0 - 0.35 * abs(detail));

    // Global contrast around mid-grey (18 nits SDR, 20 nits HDR) in log space.
    float mid = log2(hdr ? 20.0 : 18.0);
    nl = mid + (nl - mid) * (1.0 + p.contrast);
    float ny = max(exp2(nl) - 0.05, 0.0);

    // Soft roll-off into the ceiling: the panel's 1000 nits in HDR (or brighter source), white in SDR.
    float ceilY = hdr ? max(1000.0, y) : 100.0;
    float knee = 0.8 * ceilY;
    if (ny > knee) ny = knee + (ceilY - knee) * (1.0 - exp(-(ny - knee) / (ceilY - knee)));

    float3 o = l * (ny / max(y, 1e-4));

    // Vibrance: push away from grey, more for muted colours.
    float mx = max(o.r, max(o.g, o.b)), mn = min(o.r, min(o.g, o.b));
    float sat = mx > 1e-4 ? (mx - mn) / mx : 0.0;
    float k = 1.0 + p.vibrance * (1.0 - sat) * (1.0 - sat);
    o = max(ny + (o - ny) * k, 0.0);

    // Split tone: cool shadows, warm highlights, faint.
    float t = smoothstep(mid - 4.0, mid + 3.0, nl);
    float3 tint = mix(float3(-0.6, 0.0, 1.0), float3(0.8, 0.35, -0.4), t);
    o *= 1.0 + p.tone * tint;

    frame.write(float4(fromLinear(o, hdr), 1.0), gid);
}
"""

private struct LookParams { var clarity: Float, contrast: Float, vibrance: Float, tone: Float, hdr: UInt32 }

final class EnhancedLook {
    private let device: MTLDevice
    private let basePipeline: MTLComputePipelineState
    private let applyPipeline: MTLComputePipelineState
    private let blur: MPSImageGaussianBlur
    private var base: MTLTexture?, blurred: MTLTexture?
    // Tuned on GTA-style daylight and night scenes: visible, but not cartoonish.
    var params = (clarity: Float(0.45), contrast: Float(0.10), vibrance: Float(0.35), tone: Float(0.025))

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: lookSource, options: nil),
              let b = lib.makeFunction(name: "lookBase").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let a = lib.makeFunction(name: "lookApply").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else { return nil }
        self.device = device
        basePipeline = b
        applyPipeline = a
        // Sigma 3 cells on the 1/8 grid: local means over roughly 50 px of the full frame.
        blur = MPSImageGaussianBlur(device: device, sigma: 3)
        blur.edgeMode = .clamp
    }

    /// Grades `frame` (rgba16Float, gamma or PQ encoded) in place.
    func encode(_ cb: MTLCommandBuffer, frame: MTLTexture, hdr: Bool) {
        let bw = max(frame.width / 8, 1), bh = max(frame.height / 8, 1)
        if base?.width != bw || base?.height != bh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: bw, height: bh, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            base = device.makeTexture(descriptor: d)
            blurred = device.makeTexture(descriptor: d)
        }
        guard let base, let blurred else { return }
        var p = LookParams(clarity: params.clarity, contrast: params.contrast, vibrance: params.vibrance,
                           tone: params.tone, hdr: hdr ? 1 : 0)
        let size = MemoryLayout<LookParams>.size
        let tg = MTLSize(width: 16, height: 16, depth: 1)

        guard let e1 = cb.makeComputeCommandEncoder() else { return }
        e1.setComputePipelineState(basePipeline)
        e1.setTexture(frame, index: 0)
        e1.setTexture(base, index: 1)
        e1.setBytes(&p, length: size, index: 0)
        e1.dispatchThreads(MTLSize(width: bw, height: bh, depth: 1), threadsPerThreadgroup: tg)
        e1.endEncoding()

        blur.encode(commandBuffer: cb, sourceTexture: base, destinationTexture: blurred)

        guard let e2 = cb.makeComputeCommandEncoder() else { return }
        e2.setComputePipelineState(applyPipeline)
        e2.setTexture(frame, index: 0)
        e2.setTexture(blurred, index: 1)
        e2.setBytes(&p, length: size, index: 0)
        e2.dispatchThreads(MTLSize(width: frame.width, height: frame.height, depth: 1), threadsPerThreadgroup: tg)
        e2.endEncoding()
    }
}
