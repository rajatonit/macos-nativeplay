// Generates a 1080p60 HEVC test clip with fine detail (text, thin lines, gradients).
// Usage: swift Tools/make-sample.swift samples/test-1080p.mov
import AVFoundation
import AppKit
import CoreVideo

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test-1080p.mov")
try? FileManager.default.removeItem(at: out)
let w = 1920, h = 1080, fps: Int32 = 60, total = 300

let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 15_000_000],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
for i in 0..<total {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let pb else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let t = CGFloat(i) / CGFloat(total)
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.05, green: 0.08, blue: 0.2, alpha: 1), CGColor(red: 0.9, green: 0.45, blue: 0.1, alpha: 1),
    ] as CFArray, locations: nil)!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
    ctx.setLineWidth(1)
    for k in 0..<60 {  // slowly rotating fan of 1px lines
        let a = CGFloat(k) / 60 * .pi + t * .pi / 2
        ctx.move(to: CGPoint(x: 960, y: 540))
        ctx.addLine(to: CGPoint(x: 960 + cos(a) * 500, y: 540 + sin(a) * 500))
    }
    ctx.strokePath()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (row, size) in [10, 14, 20, 32].enumerated() {  // scrolling text at several sizes
        let s = NSAttributedString(
            string: "The quick brown fox jumps over the lazy dog 0123456789 — frame \(i)",
            attributes: [.font: NSFont.systemFont(ofSize: CGFloat(size)), .foregroundColor: NSColor.white])
        s.draw(at: CGPoint(x: 40 + t * 300, y: CGFloat(60 + row * 50)))
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print(writer.status == .completed ? "wrote \(out.path)" : "failed: \(String(describing: writer.error))")
