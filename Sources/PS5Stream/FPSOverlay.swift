// Live frame-rate readout drawn into the picture's top-right corner (F toggles, remembered).
//
// It's part of the frame itself, so it shows in full screen, in the app's recordings (R) and in phone
// videos of the screen. With frame generation on it splits the count into frames from the PS5 and
// generated frames, so a "120 fps" claim is never ambiguous.

import AppKit
import CoreText
import Metal

private let overlaySource = """
#include <metal_stdlib>
using namespace metal;
// Premultiplied white-on-dark label blended over the frame; `white` is the text level (PQ for HDR).
kernel void overlay(texture2d<float, access::read> label [[texture(0)]],
                    texture2d<float, access::read_write> frame [[texture(1)]],
                    constant float3 &params [[buffer(0)]],  // origin x, origin y, white level
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= label.get_width() || gid.y >= label.get_height()) return;
    uint2 p = gid + uint2(params.xy);
    if (p.x >= frame.get_width() || p.y >= frame.get_height()) return;
    float4 l = label.read(gid);
    float4 f = frame.read(p);
    frame.write(float4(l.rgb * params.z + f.rgb * (1.0 - l.a), 1.0), p);
}
"""

final class FPSOverlay {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private var texture: MTLTexture?
    private var text = ""

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: overlaySource, options: nil),
              let fn = lib.makeFunction(name: "overlay"),
              let p = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.device = device
        pipeline = p
    }

    /// Redraws the label (cheap; called once a second). `pixelSize` is the font size in frame pixels.
    func update(_ newText: String, pixelSize: CGFloat) {
        guard newText != text || texture == nil else { return }
        text = newText
        let font = CTFontCreateUIFontForLanguage(.system, pixelSize, nil)
            .flatMap { CTFontCreateCopyWithSymbolicTraits($0, pixelSize, nil, .traitBold, .traitBold) ?? $0 }
        let attr = NSAttributedString(string: text, attributes: [
            .font: font as Any, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let padX = pixelSize * 0.55, padY = pixelSize * 0.3
        let w = Int(ceil(bounds.width + 2 * padX)), h = Int(ceil(pixelSize * 1.25 + 2 * padY))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: CGFloat(h) * 0.25,
                           cornerHeight: CGFloat(h) * 0.25, transform: nil))
        ctx.fillPath()
        ctx.textPosition = CGPoint(x: padX - bounds.minX, y: (CGFloat(h) - pixelSize) / 2 + pixelSize * 0.2)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return }
        // Bitmap context memory is top row first, the same as a Metal texture.
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        texture = t
    }

    /// Blends the label into the frame's top-right corner.
    func encode(_ cb: MTLCommandBuffer, frame: MTLTexture, hdr: Bool) {
        guard let label = texture, let enc = cb.makeComputeCommandEncoder() else { return }
        let margin = Float(frame.height) * 0.02
        // Text at ~200 nits in HDR (PQ 0.58) so it isn't a glaring highlight; near-white in SDR.
        var params = SIMD3<Float>(Float(frame.width - label.width) - margin, margin, hdr ? 0.58 : 0.92)
        enc.setComputePipelineState(pipeline)
        enc.setTexture(label, index: 0)
        enc.setTexture(frame, index: 1)
        enc.setBytes(&params, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: label.width, height: label.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
    }
}
