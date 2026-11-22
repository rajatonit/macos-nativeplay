// Records exactly what's on screen (R toggles) to ~/Movies, for demo clips and bug reports.
//
// Each presented frame is copied on the GPU into an 8-bit BT.709 frame and handed to the hardware HEVC
// encoder with the time it was shown, so 120 fps sessions record at 120 fps. HDR frames are tone-mapped
// to SDR on the way (most players and sites show SDR), keeping the highlight boost's extra range as
// brighter-but-not-clipped highlights. The per-second stats line is saved next to the video
// (<name>.stats.txt) so captions can quote the real numbers.

import AVFoundation
import CoreVideo
import Metal
import QuartzCore

private let recorderSource = """
#include <metal_stdlib>
using namespace metal;
constant float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
float3 pqToNits(float3 e) {
    float3 p = pow(max(e, 0.0), 1.0 / m2);
    return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
}
// hdr: PQ BT.2020 in, SDR BT.709 (sRGB curve) out. SDR frames are already BT.709 gamma-encoded.
kernel void toSDR(texture2d<float, access::read> src [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant uint &hdr [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 c = src.read(gid).rgb;
    if (hdr != 0) {
        float3 lin = pqToNits(c) / 203.0;  // 203 nits = SDR reference white
        const float3x3 to709 = float3x3(float3(1.6605, -0.1246, -0.0182),
                                        float3(-0.5876, 1.1329, -0.1006),
                                        float3(-0.0728, -0.0083, 1.1187));
        lin = max(to709 * lin, 0.0);
        // Extended Reinhard on the brightest channel, white at 1000 nits: keeps mid-tones, rolls off highlights.
        float peak = max(lin.r, max(lin.g, lin.b));
        const float w = 1000.0 / 203.0;
        if (peak > 0.0) lin *= (peak * (1.0 + peak / (w * w)) / (1.0 + peak)) / peak;
        c = select(1.055 * pow(saturate(lin), 1.0 / 2.4) - 0.055, lin * 12.92, lin <= 0.0031308);
    }
    dst.write(float4(saturate(c), 1.0), gid);
}
"""

final class Recorder {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private var cache: CVMetalTextureCache!
    private let queue = DispatchQueue(label: "recorder")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var start: CFTimeInterval = 0
    private var size = (0, 0)
    private var lastTime: CFTimeInterval = -1
    private var stats: FileHandle?
    private(set) var url: URL?
    private(set) var frames = 0
    private(set) var dropped = 0
    var isRecording: Bool { writer != nil }

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: recorderSource, options: nil),
              let fn = lib.makeFunction(name: "toSDR"),
              let p = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.device = device
        pipeline = p
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func begin(width: Int, height: Int) {
        guard writer == nil else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"  // local time, like macOS screen recordings
        let stamp = fmt.string(from: Date())
        let url = dir.appendingPathComponent("PS5Stream \(stamp).mp4")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { print("record: can't create \(url.path)"); return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 60_000_000,  // high, so the recording shows detail, not encoder blur
                AVVideoExpectedSourceFrameRateKey: 120,
                AVVideoAllowFrameReorderingKey: false,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        i.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard w.canAdd(i) else { return }
        w.add(i)
        guard w.startWriting() else { print("record: \(w.error?.localizedDescription ?? "can't start")"); return }
        w.startSession(atSourceTime: .zero)
        let statsURL = url.deletingPathExtension().appendingPathExtension("stats.txt")
        FileManager.default.createFile(atPath: statsURL.path, contents: nil)
        stats = try? FileHandle(forWritingTo: statsURL)
        writer = w; input = i; adaptor = a; size = (width, height)
        self.url = url
        start = CACurrentMediaTime(); lastTime = -1; frames = 0; dropped = 0
        print("record: started \(url.path)")
    }

    /// Encodes the copy of `frame` into `cb`; the frame is appended once the GPU has finished.
    func capture(_ cb: MTLCommandBuffer, frame: MTLTexture, hdr: Bool) {
        guard writer != nil, let adaptor, let pool = adaptor.pixelBufferPool else { return }
        if frame.width != size.0 || frame.height != size.1 {
            return  // window was resized mid-recording; skip until it matches again
        }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        var ref: CVMetalTexture?
        guard let pb else { return }
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, frame.width, frame.height, 0, &ref)
        guard let ref, let dst = CVMetalTextureGetTexture(ref), let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        var h: UInt32 = hdr ? 1 : 0
        enc.setBytes(&h, length: 4, index: 0)
        enc.setTexture(frame, index: 0)
        enc.setTexture(dst, index: 1)
        enc.dispatchThreads(MTLSize(width: frame.width, height: frame.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        let t = CACurrentMediaTime() - start
        cb.addCompletedHandler { [weak self] _ in
            self?.queue.async {
                guard let self, let input = self.input, let adaptor = self.adaptor, t > self.lastTime else { return }
                _ = ref
                if input.isReadyForMoreMediaData,
                   adaptor.append(pb, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600_000)) {
                    self.lastTime = t
                    self.frames += 1
                } else {
                    self.dropped += 1
                }
            }
        }
    }

    /// Saves one stats line (with its time in the recording) next to the video.
    func note(_ line: String) {
        guard isRecording else { return }
        let t = CACurrentMediaTime() - start
        queue.async { self.stats?.write(Data(String(format: "%.2f\t%@\n", t, line).utf8)) }
    }

    /// Finishes the file before returning (used when quitting).
    func endAndWait() {
        guard isRecording else { return }
        let done = DispatchSemaphore(value: 0)
        end { done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    func end(_ finished: (() -> Void)? = nil) {
        guard let w = writer else { return }
        let url = url, statsFile = stats
        writer = nil
        queue.async { [self] in
            input?.markAsFinished()
            let (f, d) = (frames, dropped)
            w.finishWriting {
                try? statsFile?.close()
                print("record: saved \(url?.path ?? "") (\(f) frames, \(d) dropped)")
                finished?()
            }
            input = nil; adaptor = nil; stats = nil
        }
    }
}
