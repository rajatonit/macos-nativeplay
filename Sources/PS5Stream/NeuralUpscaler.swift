// Neural 2x luma upscaler: the FSRCNNX networks chiaki-ng ships as mpv shaders, run on the GPU.
// HQ has 16 feature channels, Fast has 8. Tools/gen-fsrcnnx.py generates both the plain shader
// version (one kernel per layer, textures in between) and the weights as plain conv tensors.
//
// On macOS 26+ the HQ network runs as one buffer pipeline instead: the activations stay in
// zero-bordered NHWC half buffers, and the 16-channel layers run as matrix multiplies on the GPU's
// neural accelerators (Metal 4 tensor ops). Same results, less memory traffic, less heat.
//
// Only luma goes through the network; it carries nearly all visible detail. Chroma is upsampled
// with the normal sampler when the frame is converted to RGB at 2x.

import Metal

/// One network layer as a plain convolution: weights[tap][in][out] with tap = (dy+r)*k + (dx+r) for a
/// k x k kernel, bias[out], PReLU slope[out] (empty: no activation), and whether it adds the feature map.
struct FSRCNNXConv {
    var kernel: Int
    var inChannels: Int
    var outChannels: Int
    var residual: Bool
    var weights: [Float]
    var bias: [Float]
    var alpha: [Float]
}

struct FSRCNNXNetwork {
    var aggregate: String
    var convs: [FSRCNNXConv] = []
    var layers: [(kernel: String, inputs: [String], outputs: [String])]
    var source: String
}

final class NeuralUpscaler {
    private let device: MTLDevice
    private let layers: [(kernel: String, inputs: [String], outputs: [String])]
    private var pipelines: [MTLComputePipelineState] = []
    private var aggregate: MTLComputePipelineState!
    private var textures: [String: MTLTexture] = [:]
    private(set) var output: MTLTexture?
    private var size = (0, 0)

    // Buffer pipeline (HQ on macOS 26+).
    private struct Stage { var pipeline: MTLComputePipelineState; var weights, bias, alpha: MTLBuffer }
    private var stages: [Stage] = []  // feature, 4 x mapping, residual, sub-pixel (by layer)
    private var fusedLast: MTLComputePipelineState?  // mapping 4 + residual in one pass
    private var feature: MTLBuffer?, ping: MTLBuffer?, pong: MTLBuffer?
    private static let tile = 128  // pixels per matrix threadgroup; the frame width must be a multiple

    /// True when the faster buffer pipeline is in use for the current frame size.
    var usesMatrixUnits: Bool { !stages.isEmpty && feature != nil }

    init?(device: MTLDevice, network: FSRCNNXNetwork) {
        self.device = device
        layers = network.layers
        do {
            let lib = try device.makeLibrary(source: network.source, options: nil)
            for layer in layers {
                pipelines.append(try device.makeComputePipelineState(function: lib.makeFunction(name: layer.kernel)!))
            }
            aggregate = try device.makeComputePipelineState(function: lib.makeFunction(name: network.aggregate)!)
        } catch {
            print("render: neural upscaler unavailable: \(error)")
            return nil
        }
        setUpBufferPipeline(network.convs)
    }

    /// The buffer pipeline is written for FSRCNNX's 16-channel shape:
    /// 5x5 1->16, four 3x3 16->16 + PReLU, 1x1 16->16 + skip + PReLU, 3x3 16->4.
    private func setUpBufferPipeline(_ convs: [FSRCNNXConv]) {
        let shape = convs.map { "\($0.kernel)/\($0.inChannels)/\($0.outChannels)/\($0.residual)/\($0.alpha.isEmpty)" }
        let expected = ["5/1/16/false/true"] + Array(repeating: "3/16/16/false/false", count: 4)
            + ["1/16/16/true/false", "3/16/4/false/true"]
        guard #available(macOS 26.0, *), shape == expected else { return }
        let kernels = ["feature5x5", "conv3x3_16", "conv3x3_16", "conv3x3_16", "conv3x3_16", "conv1x1_16_skip", "subpixel3x3"]
        do {
            let opts = MTLCompileOptions()
            opts.languageVersion = .version4_0
            let lib = try device.makeLibrary(source: bufferSource, options: opts)
            func halves(_ v: [Float]) -> MTLBuffer {
                let h = (v.isEmpty ? [0] : v).map { Float16($0) }
                return device.makeBuffer(bytes: h, length: h.count * 2)!
            }
            stages = try zip(convs, kernels).map { conv, name in
                Stage(pipeline: try device.makeComputePipelineState(function: lib.makeFunction(name: name)!),
                      weights: halves(conv.weights), bias: halves(conv.bias), alpha: halves(conv.alpha))
            }
            fusedLast = try device.makeComputePipelineState(function: lib.makeFunction(name: "conv3x3_16_then_skip")!)
        } catch {
            print("render: matrix-unit path unavailable, using plain shaders (\(error))")
            stages = []
        }
    }

    private func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    private func prepare(_ w: Int, _ h: Int) {
        guard size != (w, h) else { return }
        size = (w, h)
        textures = [:]
        feature = nil; ping = nil; pong = nil
        output = texture(w * 2, h * 2, .r16Float)
        if !stages.isEmpty, w % Self.tile == 0 {
            // Zero-bordered (W+2) x (H+2) x 16 half buffers. Only interiors are ever written, so the
            // borders stay zero and act as the convolutions' padding.
            let length = (w + 2) * (h + 2) * 16 * 2
            func zeroed() -> MTLBuffer? {
                guard let b = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
                memset(b.contents(), 0, length)
                return b
            }
            feature = zeroed(); ping = zeroed(); pong = zeroed()
            if feature == nil || ping == nil || pong == nil { feature = nil }
            if feature != nil { return }
        }
        for layer in layers {
            for name in layer.outputs where textures[name] == nil { textures[name] = texture(w, h, .rgba16Float) }
        }
    }

    /// Encodes the network on `luma` (any single-channel normalized texture). Returns the 2x luma.
    func encode(_ cb: MTLCommandBuffer, luma: MTLTexture) -> MTLTexture? {
        let w = luma.width, h = luma.height
        prepare(w, h)
        guard let out = output, let enc = cb.makeComputeCommandEncoder() else { return nil }
        func dispatch(_ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
            enc.setComputePipelineState(p)
            let tw = p.threadExecutionWidth, th = max(1, p.maxTotalThreadsPerThreadgroup / tw / 2)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: min(th, 8), depth: 1))
        }

        if let feature, let ping, let pong {
            var size = SIMD2<Int32>(Int32(w), Int32(h))
            func bind(_ s: Stage, _ input: MTLBuffer?, _ output: MTLBuffer?) {
                enc.setBuffer(input, offset: 0, index: 0)
                enc.setBuffer(output, offset: 0, index: 1)
                enc.setBuffer(s.weights, offset: 0, index: 2)
                enc.setBuffer(s.bias, offset: 0, index: 3)
                enc.setBuffer(s.alpha, offset: 0, index: 4)
                enc.setBytes(&size, length: 8, index: 5)
                enc.setBuffer(feature, offset: 0, index: 6)
            }
            func matrix(_ s: Stage) {
                enc.setComputePipelineState(s.pipeline)
                enc.dispatchThreadgroups(MTLSize(width: w / Self.tile, height: h, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: s.pipeline.threadExecutionWidth, height: 1, depth: 1))
            }
            // feature: luma texture -> feature buffer
            bind(stages[0], nil, feature)
            enc.setTexture(luma, index: 0)
            dispatch(stages[0].pipeline, w, h)
            // mapping 1-3: feature -> ping -> pong -> ping
            bind(stages[1], feature, ping); matrix(stages[1])
            bind(stages[2], ping, pong); matrix(stages[2])
            bind(stages[3], pong, ping); matrix(stages[3])
            // mapping 4, then the 1x1 residual + skip connection on the result while it's still on chip: ping -> pong
            bind(stages[4], ping, pong)
            enc.setBuffer(stages[5].weights, offset: 0, index: 7)
            enc.setBuffer(stages[5].bias, offset: 0, index: 8)
            enc.setBuffer(stages[5].alpha, offset: 0, index: 9)
            matrix(Stage(pipeline: fusedLast!, weights: stages[4].weights, bias: stages[4].bias, alpha: stages[4].alpha))
            // sub-pixel 3x3 -> 2x luma texture
            let dst = pong
            bind(stages[6], dst, nil)
            enc.setTexture(out, index: 0)
            dispatch(stages[6].pipeline, w, h)
            enc.endEncoding()
            return out
        }

        textures["LUMA"] = luma
        for (layer, p) in zip(layers, pipelines) {
            for (i, name) in layer.inputs.enumerated() { enc.setTexture(textures[name], index: i) }
            for (i, name) in layer.outputs.enumerated() { enc.setTexture(textures[name], index: layer.inputs.count + i) }
            dispatch(p, w, h)
        }
        enc.setTexture(textures[layers.last!.outputs[0]], index: 0)
        enc.setTexture(out, index: 1)
        dispatch(aggregate, w * 2, h * 2)
        enc.endEncoding()
        textures["LUMA"] = nil
        return out
    }
}

private let bufferSource = """
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace metal;
using namespace mpp::tensor_ops;

// Activations: zero-bordered NHWC half buffers of (W+2) x (H+2) pixels x 16 channels.
// Shared bindings: 0 input, 1 output, 2 weights, 3 bias, 4 PReLU slope, 5 size (W, H), 6 feature map.

inline int pixel(int x, int y, int2 size) { return (y + 1) * (size.x + 2) + x + 1; }

// 5x5, 1 -> 16, no activation. Reads luma (clamped at the edges), writes the feature map.
kernel void feature5x5(texture2d<float, access::read> luma [[texture(0)]],
                       device half4 *outBuf [[buffer(1)]],
                       device const half4 *w [[buffer(2)]],      // [25][4] half4 = [tap][out]
                       device const half4 *bias [[buffer(3)]],
                       constant int2 &size [[buffer(5)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
    half4 a0 = bias[0], a1 = bias[1], a2 = bias[2], a3 = bias[3];
    int2 m = size - 1;
    for (int t = 0; t < 25; t++) {
        int2 p = clamp(int2(gid) + int2(t % 5 - 2, t / 5 - 2), int2(0), m);
        half v = half(luma.read(uint2(p)).x);
        a0 += v * w[t * 4]; a1 += v * w[t * 4 + 1]; a2 += v * w[t * 4 + 2]; a3 += v * w[t * 4 + 3];
    }
    int i = pixel(gid.x, gid.y, size) * 4;
    outBuf[i] = a0; outBuf[i + 1] = a1; outBuf[i + 2] = a2; outBuf[i + 3] = a3;
}

// k x k, 16 -> 16 + bias (+ feature map) + PReLU, as k*k accumulated (128 px x 16) * (16 x 16) matrix
// multiplies on the GPU's matrix units. One threadgroup = 128 pixels of one row.
template <int K, bool SKIP>
inline void conv16(device half *inBuf, device half *outBuf, device half *wBuf, device half *bias,
                   device half *alpha, device half *featBuf, int2 size, uint2 tgid)
{
    const int pw = size.x + 2;
    const int rows = pw * (size.y + 2);
    auto A = tensor<device half, dextents<int32_t, 2>, tensor_inline>(inBuf, dextents<int32_t, 2>(16, rows));
    auto B = tensor<device half, dextents<int32_t, 2>, tensor_inline>(wBuf, dextents<int32_t, 2>(16, 16 * K * K));
    auto C = tensor<device half, dextents<int32_t, 2>, tensor_inline>(outBuf, dextents<int32_t, 2>(16, rows));
    constexpr auto desc = matmul2d_descriptor(128, 16, 16, false, false, true, matmul2d_descriptor::mode::multiply_accumulate);
    matmul2d<desc, execution_simdgroups<1>> op;
    const int base = (int(tgid.y) + 1) * pw + int(tgid.x) * 128 + 1;
    auto a0 = A.slice(0, base);
    auto b0 = B.slice(0, 0);
    auto acc = op.get_destination_cooperative_tensor<decltype(a0), decltype(b0), half>();
    if (SKIP) {
        auto F = tensor<device half, dextents<int32_t, 2>, tensor_inline>(featBuf, dextents<int32_t, 2>(16, rows));
        acc.load(F.slice(0, base));
    } else {
        for (uint16_t i = 0; i < acc.get_capacity(); ++i) if (acc.is_valid_element(i)) acc[i] = 0;
    }
    #pragma unroll
    for (int t = 0; t < K * K; t++) {
        auto a = A.slice(0, base + (t / K - K / 2) * pw + (t % K - K / 2));
        auto b = B.slice(0, t * 16);
        op.run(a, b, acc);
    }
    for (uint16_t i = 0; i < acc.get_capacity(); ++i) {
        if (acc.is_valid_element(i)) {
            auto idx = acc.get_multidimensional_index(i);
            half v = acc[i] + bias[idx[0]];
            acc[i] = max(v, half(0)) + alpha[idx[0]] * min(v, half(0));
        }
    }
    acc.store(C.slice(0, base));
}

// Mapping layer 4 followed by the 1x1 residual layer: the 3x3 result goes to threadgroup memory
// instead of device memory, and feeds the 1x1 matrix multiply (+ feature map, bias, PReLU) directly.
kernel void conv3x3_16_then_skip(device half *inBuf [[buffer(0)]], device half *outBuf [[buffer(1)]],
                                 device half *w [[buffer(2)]], device half *bias [[buffer(3)]],
                                 device half *alpha [[buffer(4)]], constant int2 &size [[buffer(5)]],
                                 device half *feat [[buffer(6)]],
                                 device half *w2 [[buffer(7)]], device half *bias2 [[buffer(8)]],
                                 device half *alpha2 [[buffer(9)]],
                                 uint2 tgid [[threadgroup_position_in_grid]])
{
    threadgroup half tile[128 * 16];
    const int pw = size.x + 2;
    const int rows = pw * (size.y + 2);
    auto A = tensor<device half, dextents<int32_t, 2>, tensor_inline>(inBuf, dextents<int32_t, 2>(16, rows));
    auto B = tensor<device half, dextents<int32_t, 2>, tensor_inline>(w, dextents<int32_t, 2>(16, 144));
    auto B2 = tensor<device half, dextents<int32_t, 2>, tensor_inline>(w2, dextents<int32_t, 2>(16, 16));
    auto F = tensor<device half, dextents<int32_t, 2>, tensor_inline>(feat, dextents<int32_t, 2>(16, rows));
    auto C = tensor<device half, dextents<int32_t, 2>, tensor_inline>(outBuf, dextents<int32_t, 2>(16, rows));
    auto T = tensor<threadgroup half, dextents<int32_t, 2>, tensor_inline>(tile, dextents<int32_t, 2>(16, 128));
    constexpr auto desc = matmul2d_descriptor(128, 16, 16, false, false, true, matmul2d_descriptor::mode::multiply_accumulate);
    matmul2d<desc, execution_simdgroups<1>> op;
    const int base = (int(tgid.y) + 1) * pw + int(tgid.x) * 128 + 1;
    auto a0 = A.slice(0, base);
    auto b0 = B.slice(0, 0);
    auto acc = op.get_destination_cooperative_tensor<decltype(a0), decltype(b0), half>();
    for (uint16_t i = 0; i < acc.get_capacity(); ++i) if (acc.is_valid_element(i)) acc[i] = 0;
    #pragma unroll
    for (int t = 0; t < 9; t++) {
        auto a = A.slice(0, base + (t / 3 - 1) * pw + (t % 3 - 1));
        auto b = B.slice(0, t * 16);
        op.run(a, b, acc);
    }
    for (uint16_t i = 0; i < acc.get_capacity(); ++i) {
        if (acc.is_valid_element(i)) {
            auto idx = acc.get_multidimensional_index(i);
            half v = acc[i] + bias[idx[0]];
            acc[i] = max(v, half(0)) + alpha[idx[0]] * min(v, half(0));
        }
    }
    acc.store(T);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    auto acc2 = op.get_destination_cooperative_tensor<decltype(T), decltype(B2), half>();
    auto f = F.slice(0, base);
    acc2.load(f);
    op.run(T, B2, acc2);
    for (uint16_t i = 0; i < acc2.get_capacity(); ++i) {
        if (acc2.is_valid_element(i)) {
            auto idx = acc2.get_multidimensional_index(i);
            half v = acc2[i] + bias2[idx[0]];
            acc2[i] = max(v, half(0)) + alpha2[idx[0]] * min(v, half(0));
        }
    }
    auto c = C.slice(0, base);
    acc2.store(c);
}

kernel void conv3x3_16(device half *inBuf [[buffer(0)]], device half *outBuf [[buffer(1)]],
                       device half *w [[buffer(2)]], device half *bias [[buffer(3)]],
                       device half *alpha [[buffer(4)]], constant int2 &size [[buffer(5)]],
                       device half *feat [[buffer(6)]], uint2 tgid [[threadgroup_position_in_grid]])
{
    conv16<3, false>(inBuf, outBuf, w, bias, alpha, feat, size, tgid);
}

kernel void conv1x1_16_skip(device half *inBuf [[buffer(0)]], device half *outBuf [[buffer(1)]],
                            device half *w [[buffer(2)]], device half *bias [[buffer(3)]],
                            device half *alpha [[buffer(4)]], constant int2 &size [[buffer(5)]],
                            device half *feat [[buffer(6)]], uint2 tgid [[threadgroup_position_in_grid]])
{
    conv16<1, true>(inBuf, outBuf, w, bias, alpha, feat, size, tgid);
}

// 3x3, 16 -> 4 sub-pixel convolution, written straight out as the 2x2 output pixels.
kernel void subpixel3x3(device const half4 *inBuf [[buffer(0)]],
                        device const half4 *w [[buffer(2)]],      // [9][16] half4 = [tap][in] -> 4 outputs
                        device const half4 *bias [[buffer(3)]],
                        constant int2 &size [[buffer(5)]],
                        texture2d<half, access::write> out [[texture(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
    half4 r = bias[0];
    for (int t = 0; t < 9; t++) {
        int i = pixel(int(gid.x) + t % 3 - 1, int(gid.y) + t / 3 - 1, size) * 4;
        for (int q = 0; q < 4; q++) {
            half4 v = inBuf[i + q];
            int k = (t * 16 + q * 4);
            r += v.x * w[k] + v.y * w[k + 1] + v.z * w[k + 2] + v.w * w[k + 3];
        }
    }
    uint2 o = gid * 2;
    out.write(half4(r[0]), o);
    out.write(half4(r[1]), o + uint2(0, 1));
    out.write(half4(r[2]), o + uint2(1, 0));
    out.write(half4(r[3]), o + uint2(1, 1));
}
"""
