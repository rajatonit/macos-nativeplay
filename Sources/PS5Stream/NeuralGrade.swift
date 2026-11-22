// "AI grade" (G toggles, remembered): a small network trained to make the picture look more like real
// camera footage: less haze, deeper sky, truer contrast. See Tools/relight for how it was trained (an
// image model, FLUX.1-schnell, made "photoreal" versions of game frames offline; this network learned
// the light and colour part of that change). Only the 290 KB of weights ship; nothing else is needed.
//
// How it runs (HDRNet-style bilateral grid):
//   1. The frame is shrunk to 256x144 and a CNN predicts a 16 x 9 x 8 grid of 3x4 colour transforms
//      (across the picture, down it, and by brightness). ~0.2 ms.
//   2. The grid is smoothed over time so scene changes ease in rather than flicker.
//   3. Every pixel looks up its transform by position and brightness (hardware trilinear filtering of
//      3D textures) and applies it to its own colour. One lookup and a 3x4 multiply per pixel.
// It can only change light and colour smoothly, never move or invent pixels, so it can't smear.
//
// The network works on SDR (sRGB-encoded BT.709) like the recordings it was trained on. HDR frames are
// converted into that space with the recorder's tone curve and back again afterwards; colours outside
// BT.709 and highlights above 1000 nits pass through unchanged.

import Foundation
import Metal

private let gradeSource = """
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
float3 srgbEncode(float3 l) { l = saturate(l); return select(1.055 * pow(l, 1.0 / 2.4) - 0.055, l * 12.92, l <= 0.0031308); }
float3 srgbDecode(float3 e) { e = saturate(e); return select(pow((e + 0.055) / 1.055, 2.4), e / 12.92, e <= 0.04045); }
constant float3x3 to709 = float3x3(float3(1.6605, -0.1246, -0.0182), float3(-0.5876, 1.1329, -0.1006), float3(-0.0728, -0.0083, 1.1187));
constant float3x3 to2020 = float3x3(float3(0.6274, 0.0691, 0.0164), float3(0.3293, 0.9195, 0.0880), float3(0.0433, 0.0114, 0.8956));
constant float W = 1000.0 / 203.0;   // tone curve's white point (recorder): 1000 nits

// PQ BT.2020 -> the network's space (exactly the recorder's tone map). `resid` keeps what BT.709 can't hold.
float3 hdrToSDR(float3 e, thread float3 &resid, thread float &peakIn) {
    float3 lin = pqToNits(e) / 203.0;
    float3 l709 = max(to709 * lin, 0.0);
    resid = lin - to2020 * l709;
    float peak = max(l709.r, max(l709.g, l709.b));
    peakIn = peak;
    if (peak > 0.0) l709 *= (1.0 + peak / (W * W)) / (1.0 + peak);
    return srgbEncode(l709);
}
float3 sdrToHDR(float3 s, float3 resid) {
    float3 t = srgbDecode(s);
    float y = max(t.r, max(t.g, t.b));
    if (y > 0.0) {
        // Inverse of y = x (1 + x/W^2) / (1 + x)
        float a = 1.0 / (W * W), b = 1.0 - y;
        float x = (-b + sqrt(b * b + 4.0 * a * y)) / (2.0 * a);
        t *= x / y;
    }
    return nitsToPQ(max(to2020 * t + resid, 0.0) * 203.0);
}

// 1. Frame -> 3 x 144 x 256 in the network's space (4x4 samples per output pixel).
kernel void gradeInput(texture2d<float, access::sample> frame [[texture(0)]],
                       device float *dst [[buffer(0)]],
                       constant uint &hdr [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    const uint w = 256, h = 144;
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 acc = 0;
    for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
        float2 uv = (float2(gid) + (float2(i, j) + 0.5) / 4.0) / float2(w, h);
        float3 c = frame.sample(s, uv).rgb;
        float3 r; float pk;
        acc += hdr != 0 ? hdrToSDR(c, r, pk) : saturate(c);
    }
    acc /= 16.0;
    for (uint k = 0; k < 3; k++) dst[(k * h + gid.y) * w + gid.x] = acc[k];
}

struct ConvP { uint cin, cout, inW, inH, outW, outH, stride, relu, ksize, addChannel; };
// 3x3 (pad 1) or 1x1 convolution, CHW float buffers; optional per-channel add before the ReLU.
kernel void gradeConv(device const float *src [[buffer(0)]],
                      device float *dst [[buffer(1)]],
                      device const float *wt [[buffer(2)]],
                      device const float *bias [[buffer(3)]],
                      device const float *add [[buffer(4)]],
                      constant ConvP &p [[buffer(5)]],
                      uint3 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.outW || gid.y >= p.outH || gid.z >= p.cout) return;
    uint co = gid.z;
    float sum = bias[co];
    int k = int(p.ksize), pad = k / 2;
    for (uint ci = 0; ci < p.cin; ci++) {
        device const float *wc = wt + (co * p.cin + ci) * k * k;
        device const float *sc = src + ci * p.inW * p.inH;
        for (int ky = 0; ky < k; ky++) {
            int iy = int(gid.y * p.stride) - pad + ky;
            if (iy < 0 || iy >= int(p.inH)) continue;
            for (int kx = 0; kx < k; kx++) {
                int ix = int(gid.x * p.stride) - pad + kx;
                if (ix < 0 || ix >= int(p.inW)) continue;
                sum += wc[ky * k + kx] * sc[iy * p.inW + ix];
            }
        }
    }
    if (p.addChannel != 0) sum += add[co];
    if (p.relu != 0) sum = max(sum, 0.0);
    dst[(co * p.outH + gid.y) * p.outW + gid.x] = sum;
}

// Global context: channel means, then two small fully connected layers (one thread group of 64).
kernel void gradeGlobal(device const float *feat [[buffer(0)]],
                        device float *g [[buffer(1)]],
                        device const float *w0 [[buffer(2)]], device const float *b0 [[buffer(3)]],
                        device const float *w1 [[buffer(4)]], device const float *b1 [[buffer(5)]],
                        uint t [[thread_position_in_threadgroup]]) {
    threadgroup float mean[64], hid[64];
    float s = 0;
    for (uint i = 0; i < 144; i++) s += feat[t * 144 + i];
    mean[t] = s / 144.0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float a = b0[t];
    for (uint i = 0; i < 64; i++) a += w0[t * 64 + i] * mean[i];
    hid[t] = max(a, 0.0);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float o = b1[t];
    for (uint i = 0; i < 64; i++) o += w1[t * 64 + i] * hid[i];
    g[t] = o;
}

// 2. Smooth the grid over time and store it as three 3D textures (one per output channel: 4 coefficients).
kernel void gradeGrid(device const float *grid [[buffer(0)]],   // 96 x 9 x 16 (depth*12 + row*4 + col)
                      device float *state [[buffer(1)]],
                      constant float &keep [[buffer(2)]],       // 0 = take the new grid as is
                      texture3d<float, access::write> r0 [[texture(0)]],
                      texture3d<float, access::write> r1 [[texture(1)]],
                      texture3d<float, access::write> r2 [[texture(2)]],
                      uint3 gid [[thread_position_in_grid]]) {   // x 0..15, y 0..8, depth 0..7
    if (gid.x >= 16 || gid.y >= 9 || gid.z >= 8) return;
    float c[12];
    for (uint j = 0; j < 12; j++) {
        uint idx = ((gid.z * 12 + j) * 9 + gid.y) * 16 + gid.x;
        float v = mix(grid[idx], state[idx], keep);
        state[idx] = v;
        c[j] = v;
    }
    r0.write(float4(c[0], c[1], c[2], c[3]), gid);
    r1.write(float4(c[4], c[5], c[6], c[7]), gid);
    r2.write(float4(c[8], c[9], c[10], c[11]), gid);
}

// 3. Every pixel: look up its transform and apply it (blended by `strength`).
kernel void gradeApply(texture2d<float, access::read_write> frame [[texture(0)]],
                       texture3d<float, access::sample> r0 [[texture(1)]],
                       texture3d<float, access::sample> r1 [[texture(2)]],
                       texture3d<float, access::sample> r2 [[texture(3)]],
                       constant float2 &params [[buffer(0)]],    // strength, hdr
                       uint2 gid [[thread_position_in_grid]]) {
    uint w = frame.get_width(), h = frame.get_height();
    if (gid.x >= w || gid.y >= h) return;
    bool hdr = params.y > 0.5;
    float3 e = frame.read(gid).rgb;
    float3 resid = 0; float peak = 0;
    float3 s = hdr ? hdrToSDR(e, resid, peak) : saturate(e);
    // Grid coordinates as in training (align_corners): pixel 0 -> cell 0, last pixel -> last cell.
    float gx = float(gid.x) / float(w - 1) * 15.0, gy = float(gid.y) / float(h - 1) * 8.0;
    float gz = saturate(dot(s, float3(0.2126, 0.7152, 0.0722))) * 7.0;
    float3 uvw = (float3(gx, gy, gz) + 0.5) / float3(16, 9, 8);
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float4 a = r0.sample(smp, uvw), b = r1.sample(smp, uvw), c = r2.sample(smp, uvw);
    float3 o = float3(dot(a.xyz, s) + a.w, dot(b.xyz, s) + b.w, dot(c.xyz, s) + c.w);
    float k = params.x;
    if (hdr) k *= 1.0 - smoothstep(0.85 * W, W, peak);  // leave the brightest highlights alone
    o = saturate(s + k * (o - s));
    frame.write(float4(hdr ? sdrToHDR(o, resid) : o, 1.0), gid);
}
"""

private struct ConvP { var cin, cout, inW, inH, outW, outH, stride, relu, ksize, addChannel: UInt32 }

final class NeuralGrade {
    private let device: MTLDevice
    private let input, conv, global, grid, apply: MTLComputePipelineState
    private var weights: [String: MTLBuffer] = [:]
    private let bufIn, buf1, buf2, buf3, buf4, buf5, buf6, gBuf, gridBuf, state, zeros: MTLBuffer
    private let r0, r1, r2: MTLTexture
    private var fresh = true
    /// How much of the change to apply (1 = what the network learned).
    var strength: Float = 1.0

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: gradeSource, options: nil) else { return nil }
        func pipe(_ n: String) -> MTLComputePipelineState? { lib.makeFunction(name: n).flatMap { try? device.makeComputePipelineState(function: $0) } }
        guard let i = pipe("gradeInput"), let c = pipe("gradeConv"), let g = pipe("gradeGlobal"),
              let gr = pipe("gradeGrid"), let a = pipe("gradeApply") else { return nil }
        self.device = device
        (input, conv, global, grid, apply) = (i, c, g, gr, a)

        // Weights: fp16, base64, in PyTorch state_dict order (see NeuralGradeWeights.swift).
        guard let data = Data(base64Encoded: neuralGradeWeights, options: .ignoreUnknownCharacters) else { return nil }
        let halves = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        let layout: [(String, Int)] = [
            ("down0.w", 16 * 3 * 9), ("down0.b", 16), ("down1.w", 32 * 16 * 9), ("down1.b", 32),
            ("down2.w", 64 * 32 * 9), ("down2.b", 64), ("down3.w", 64 * 64 * 9), ("down3.b", 64),
            ("local0.w", 64 * 64 * 9), ("local0.b", 64), ("local2.w", 64 * 64 * 9), ("local2.b", 64),
            ("glob0.w", 64 * 64), ("glob0.b", 64), ("glob2.w", 64 * 64), ("glob2.b", 64),
            ("out.w", 96 * 64), ("out.b", 96),
        ]
        guard layout.reduce(0, { $0 + $1.1 }) == halves.count else {
            print("grade: weights don't match the network (\(halves.count) values)")
            return nil
        }
        var at = 0
        for (name, n) in layout {
            let floats = halves[at..<at + n].map { Float($0) }
            at += n
            guard let b = device.makeBuffer(bytes: floats, length: n * 4) else { return nil }
            weights[name] = b
        }
        func buf(_ n: Int) -> MTLBuffer { device.makeBuffer(length: n * 4, options: .storageModePrivate)! }
        bufIn = buf(3 * 144 * 256); buf1 = buf(16 * 72 * 128); buf2 = buf(32 * 36 * 64); buf3 = buf(64 * 18 * 32)
        buf4 = buf(64 * 9 * 16); buf5 = buf(64 * 9 * 16); buf6 = buf(64 * 9 * 16)
        gBuf = buf(64); gridBuf = buf(96 * 9 * 16); state = buf(96 * 9 * 16)
        zeros = device.makeBuffer(length: 64 * 4)!
        let td = MTLTextureDescriptor()
        td.textureType = .type3D
        td.pixelFormat = .rgba32Float
        (td.width, td.height, td.depth) = (16, 9, 8)
        td.usage = [.shaderRead, .shaderWrite]
        td.storageMode = .private
        guard let t0 = device.makeTexture(descriptor: td), let t1 = device.makeTexture(descriptor: td),
              let t2 = device.makeTexture(descriptor: td) else { return nil }
        (r0, r1, r2) = (t0, t1, t2)
    }

    /// Call when the picture jumps (new session, seek) so the grid doesn't ease in from the old scene.
    func reset() { fresh = true }

    /// Grades `frame` (rgba16Float, gamma or PQ encoded) in place.
    func encode(_ cb: MTLCommandBuffer, frame: MTLTexture, hdr: Bool) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        var hdrFlag: UInt32 = hdr ? 1 : 0
        enc.setComputePipelineState(input)
        enc.setTexture(frame, index: 0)
        enc.setBuffer(bufIn, offset: 0, index: 0)
        enc.setBytes(&hdrFlag, length: 4, index: 1)
        enc.dispatchThreads(MTLSize(width: 256, height: 144, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))

        func layer(_ src: MTLBuffer, _ dst: MTLBuffer, _ name: String, cin: Int, cout: Int, inW: Int, inH: Int,
                   stride: Int, relu: Bool, k: Int = 3, add: MTLBuffer? = nil) {
            let outW = (inW + 2 * (k / 2) - k) / stride + 1, outH = (inH + 2 * (k / 2) - k) / stride + 1
            var p = ConvP(cin: UInt32(cin), cout: UInt32(cout), inW: UInt32(inW), inH: UInt32(inH), outW: UInt32(outW),
                          outH: UInt32(outH), stride: UInt32(stride), relu: relu ? 1 : 0, ksize: UInt32(k), addChannel: add == nil ? 0 : 1)
            enc.memoryBarrier(scope: .buffers)
            enc.setComputePipelineState(conv)
            enc.setBuffer(src, offset: 0, index: 0)
            enc.setBuffer(dst, offset: 0, index: 1)
            enc.setBuffer(weights[name + ".w"], offset: 0, index: 2)
            enc.setBuffer(weights[name + ".b"], offset: 0, index: 3)
            enc.setBuffer(add ?? zeros, offset: 0, index: 4)
            enc.setBytes(&p, length: MemoryLayout<ConvP>.stride, index: 5)
            enc.dispatchThreads(MTLSize(width: outW, height: outH, depth: cout),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        }
        layer(bufIn, buf1, "down0", cin: 3, cout: 16, inW: 256, inH: 144, stride: 2, relu: true)
        layer(buf1, buf2, "down1", cin: 16, cout: 32, inW: 128, inH: 72, stride: 2, relu: true)
        layer(buf2, buf3, "down2", cin: 32, cout: 64, inW: 64, inH: 36, stride: 2, relu: true)
        layer(buf3, buf4, "down3", cin: 64, cout: 64, inW: 32, inH: 18, stride: 2, relu: true)   // 16 x 9

        enc.memoryBarrier(scope: .buffers)
        enc.setComputePipelineState(global)
        enc.setBuffer(buf4, offset: 0, index: 0)
        enc.setBuffer(gBuf, offset: 0, index: 1)
        enc.setBuffer(weights["glob0.w"], offset: 0, index: 2); enc.setBuffer(weights["glob0.b"], offset: 0, index: 3)
        enc.setBuffer(weights["glob2.w"], offset: 0, index: 4); enc.setBuffer(weights["glob2.b"], offset: 0, index: 5)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))

        layer(buf4, buf5, "local0", cin: 64, cout: 64, inW: 16, inH: 9, stride: 1, relu: true)
        layer(buf5, buf6, "local2", cin: 64, cout: 64, inW: 16, inH: 9, stride: 1, relu: true, add: gBuf)
        layer(buf6, gridBuf, "out", cin: 64, cout: 96, inW: 16, inH: 9, stride: 1, relu: false, k: 1)

        // About a third of a second to settle at 60 fps.
        var keep: Float = fresh ? 0 : 0.85
        fresh = false
        enc.memoryBarrier(scope: .buffers)
        enc.setComputePipelineState(grid)
        enc.setBuffer(gridBuf, offset: 0, index: 0)
        enc.setBuffer(state, offset: 0, index: 1)
        enc.setBytes(&keep, length: 4, index: 2)
        enc.setTexture(r0, index: 0); enc.setTexture(r1, index: 1); enc.setTexture(r2, index: 2)
        enc.dispatchThreads(MTLSize(width: 16, height: 9, depth: 8), threadsPerThreadgroup: MTLSize(width: 16, height: 9, depth: 1))
        enc.endEncoding()

        guard let e2 = cb.makeComputeCommandEncoder() else { return }
        var params = SIMD2<Float>(strength, hdr ? 1 : 0)
        e2.setComputePipelineState(apply)
        e2.setTexture(frame, index: 0)
        e2.setTexture(r0, index: 1); e2.setTexture(r1, index: 2); e2.setTexture(r2, index: 3)
        e2.setBytes(&params, length: 8, index: 0)
        e2.dispatchThreads(MTLSize(width: frame.width, height: frame.height, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e2.endEncoding()
    }
}
