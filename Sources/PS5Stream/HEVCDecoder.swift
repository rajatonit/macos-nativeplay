// Hardware HEVC decode of the Annex-B access units libchiaki hands us.

import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

final class HEVCDecoder {
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// 10-bit output for HDR streams, 8-bit otherwise. Set before the first frame.
    var tenBit = false
    private(set) var lastDecodeMs = 0.0
    /// Brightest pixel and 99th percentile of a recent HDR frame, in nits.
    private(set) var peakNits = 0.0
    private(set) var brightNits = 0.0
    private(set) var samplesIn = 0
    private(set) var framesOut = 0
    private var loggedFormat = false

    private var vps: Data?, sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// Splits an Annex-B buffer into NAL units (without start codes).
    private func nalUnits(_ buf: UnsafeBufferPointer<UInt8>) -> [UnsafeBufferPointer<UInt8>] {
        var starts: [Int] = []
        let n = buf.count
        var i = 0
        while i + 2 < n {
            if buf[i] == 0, buf[i + 1] == 0, buf[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        var units: [UnsafeBufferPointer<UInt8>] = []
        for (k, s) in starts.enumerated() {
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : n
            while e > s, buf[e - 1] == 0 { e -= 1 }  // a NAL never ends in a zero byte
            if e > s { units.append(UnsafeBufferPointer(rebasing: buf[s..<e])) }
        }
        return units
    }

    private func rebuildSession() -> Bool {
        guard let vps, let sps, let pps else { return false }
        var fmt: CMVideoFormatDescription?
        let status: OSStatus = vps.withUnsafeBytes { v in
            sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let ptrs = [v, s, p].map { $0.bindMemory(to: UInt8.self).baseAddress! }
                    let sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: 3, parameterSetPointers: ptrs,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                        formatDescriptionOut: &fmt)
                }
            }
        }
        guard status == noErr, let fmt else {
            print("decoder: bad parameter sets (\(status))")
            return false
        }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        // Ask for a plain bi-planar format; otherwise Apple Silicon may hand back
        // lossless-compressed buffers that the renderer does not handle.
        let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
        ] as CFDictionary
        var s: VTDecompressionSession?
        let err = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: fmt, decoderSpecification: nil,
            imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &s)
        guard err == noErr, let s else {
            print("decoder: could not create session (\(err))")
            return false
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        format = fmt
        session = s
        let d = CMVideoFormatDescriptionGetDimensions(fmt)
        print("decoder: HEVC \(d.width)x\(d.height)")
        return true
    }

    /// Diagnostic: brightest luma in the frame, converted to nits if the stream is PQ.
    private func measure(_ pb: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var hist = [Int](repeating: 0, count: 1024)
        for y in Swift.stride(from: 0, to: h, by: 2) {
            let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
            for x in Swift.stride(from: 0, to: w, by: 2) { hist[Int(row[x] >> 6)] += 1 }
        }
        let total = hist.reduce(0, +)
        func pct(_ p: Double) -> Int {
            var acc = 0
            for (v, n) in hist.enumerated() { acc += n; if Double(acc) >= p * Double(total) { return v } }
            return 1023
        }
        func nits(_ code: Int) -> Double {
            let e = max(0, min(1, Double(code - 64) / 876))
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            let p = pow(e, 1 / m2)
            return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
        }
        let maxCode = hist.lastIndex { $0 > 0 } ?? 0
        peakNits = nits(maxCode)
        brightNits = nits(pct(0.99))
    }

    /// Returns false when the frame could not be decoded (the caller then asks for a keyframe).
    func decode(_ buf: UnsafeBufferPointer<UInt8>) -> Bool {
        var sample = Data()
        var paramsChanged = false
        for nal in nalUnits(buf) {
            let type = (nal[0] >> 1) & 0x3f
            switch type {
            case 32, 33, 34:
                let d = Data(nal)
                if type == 32, vps != d { vps = d; paramsChanged = true }
                if type == 33, sps != d { sps = d; paramsChanged = true }
                if type == 34, pps != d { pps = d; paramsChanged = true }
            case 0..<32:  // picture data
                var len = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &len) { sample.append(contentsOf: $0) }
                sample.append(nal)
            default:
                break  // AUD, SEI etc.
            }
        }
        if paramsChanged || (session == nil && vps != nil) {
            guard rebuildSession() else { return false }
        }
        guard !sample.isEmpty else { return true }  // header-only buffer
        guard let session, let format else { return false }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: sample.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: sample.count, flags: 0,
            blockBufferOut: &block) == noErr, let block
        else { return false }
        _ = sample.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.count)
        }
        var sb: CMSampleBuffer?
        var size = sample.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb
        else { return false }

        samplesIn += 1
        let t0 = CACurrentMediaTime()
        var ok = false
        // No async flag: the handler runs before DecodeFrame returns.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            if status == noErr, let image {
                ok = true
                guard let self else { return }
                self.framesOut += 1
                if !self.loggedFormat {
                    self.loggedFormat = true
                    let f = CVPixelBufferGetPixelFormatType(image)
                    let code = String((0..<4).map { Character(UnicodeScalar(UInt8((f >> (24 - $0 * 8)) & 0xff))) })
                    let tf = CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil) as? String ?? "none"
                    let prim = CVBufferCopyAttachment(image, kCVImageBufferColorPrimariesKey, nil) as? String ?? "none"
                    print("decoder: first frame \(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) format '\(code)' transfer \(tf) primaries \(prim)")
                }
                if self.framesOut % 120 == 0 { self.measure(image) }
                self.onFrame?(image)
            } else if status != noErr {
                print("decoder: frame error \(status)")
            }
        }
        lastDecodeMs = (CACurrentMediaTime() - t0) * 1000
        if status == kVTInvalidSessionErr { self.session = nil }
        return status == noErr && ok
    }
}
