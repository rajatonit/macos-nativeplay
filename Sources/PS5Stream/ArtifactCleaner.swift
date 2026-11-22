// Removes compression artifacts from the decoded frame before it's upscaled (D toggles).
//
// At 30 Mbit/s the PS5's encoder flattens smooth areas (sky, fog, dark walls, skin) into visible steps:
// banding, plus faint 8x8 / 16x16 block edges where a gradient was coded as flat blocks. The neural
// upscaler sharpens whatever it's given, so those steps get sharper too. This pass undoes them first.
//
// Method (deband, as in mpv / libplacebo, made stricter): for each pixel, four samples are taken at a
// random direction and distance around it (a cross, so the average is centred). If every sample is
// within a few code values of the pixel, the area is a smooth gradient that the encoder stepped, and
// the pixel is replaced by the average. Any real detail, edge or texture makes at least one sample
// differ by more than the threshold, and the pixel is left exactly as decoded. Two passes run: a
// short reach for small steps, then a wider one with a tighter threshold for broad bands. The result
// is kept as half floats all the way to the screen, so the smoothed gradients aren't re-quantised.

import Metal

private let cleanerSource = """
#include <metal_stdlib>
using namespace metal;

struct Params { float threshold; float radius; };

static float hash(uint2 p, uint s) {
    uint h = p.x * 1973u + p.y * 9277u + s * 26699u;
    h ^= h >> 15; h *= 0x2c1b3c6du; h ^= h >> 12; h *= 0x297a2d39u; h ^= h >> 15;
    return float(h & 0xffffu) / 65536.0;
}

// Works for any plane: luma (r) or chroma (rg); unused channels are ignored by the caller's format.
kernel void deband(texture2d<float, access::sample> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   constant Params &p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::pixel);
    float2 c = float2(gid) + 0.5;
    float4 orig = src.read(gid);
    float4 res = orig;
    for (uint it = 1; it <= 2; it++) {
        // Direction and distance are fixed per pixel (not per frame), so a static image stays still.
        float a = hash(gid, it * 2u) * 6.2831853;
        float d = p.radius * float(it) * (0.4 + 0.6 * hash(gid, it * 2u + 1u));
        float2 o = float2(cos(a), sin(a)) * d, q = float2(-o.y, o.x);
        float4 s0 = src.sample(s, c + o), s1 = src.sample(s, c - o);
        float4 s2 = src.sample(s, c + q), s3 = src.sample(s, c - q);
        float4 dev = max(max(abs(s0 - orig), abs(s1 - orig)), max(abs(s2 - orig), abs(s3 - orig)));
        float4 avg = (s0 + s1 + s2 + s3) * 0.25;
        float thr = p.threshold / float(it);
        res = select(res, avg, dev < thr);
    }
    dst.write(res, gid);
}
"""

final class ArtifactCleaner {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private var luma: MTLTexture?
    private var chroma: MTLTexture?

    /// Steps smaller than this many code values (at the stream's bit depth) count as compression
    /// artifacts. Real detail in a smooth area rarely varies this little across 10-20 pixels.
    var codes: Float = 4
    /// Reach of the first pass in source pixels (the second is twice this).
    var radius: Float = 8

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: cleanerSource, options: nil),
              let fn = lib.makeFunction(name: "deband"),
              let p = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.device = device
        pipeline = p
    }

    private func texture(_ old: MTLTexture?, _ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
        if let old, old.width == w, old.height == h, old.pixelFormat == format { return old }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// Encodes the clean-up of both planes; returns cleaned luma and chroma (same normalised values as
    /// the inputs, as half floats). `bits` is the stream's bit depth (8 or 10).
    func encode(_ cb: MTLCommandBuffer, luma src: MTLTexture, chroma csrc: MTLTexture, bits: Int) -> (MTLTexture, MTLTexture)? {
        luma = texture(luma, .r16Float, src.width, src.height)
        chroma = texture(chroma, .rg16Float, csrc.width, csrc.height)
        guard let luma, let chroma, let enc = cb.makeComputeCommandEncoder() else { return nil }
        let code = 1 / Float((1 << bits) - 1)
        enc.setComputePipelineState(pipeline)
        for (s, d, r) in [(src, luma, radius), (csrc, chroma, radius / 2)] {  // chroma is half size
            var p = (threshold: codes * code, radius: r)
            enc.setBytes(&p, length: MemoryLayout.size(ofValue: p), index: 0)
            enc.setTexture(s, index: 0)
            enc.setTexture(d, index: 1)
            enc.dispatchThreads(MTLSize(width: d.width, height: d.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        }
        enc.endEncoding()
        return (luma, chroma)
    }
}
