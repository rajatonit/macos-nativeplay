// Works out the game's real frame rate from the PS5's 60 fps stream.
//
// A 30 fps game is streamed at 60 fps by sending every picture twice. The repeat isn't bit-identical
// after HEVC, but it's far closer to the frame before it than a new picture is. Each frame is compared
// with the previous one on a sparse grid (32,000 luma samples, a fraction of a millisecond on the CPU):
// a difference well below the recent level of motion means "repeat".
//
// `halfRate` switches on when repeats keep alternating with new pictures (a 30 fps game) and off when
// they stop. In a still scene every frame looks like a repeat, so the mode is kept as it was.

import CoreVideo
import Foundation

final class FrameCadence {
    private var previous: [UInt8] = []
    private var motion = 2.0          // typical difference between new pictures (8-bit code values)
    private var history: [Bool] = []  // recent frames: true = repeat
    private(set) var halfRate = false
    private var uniqueThisSecond = 0, framesThisSecond = 0
    private var secondStart = CFAbsoluteTimeGetCurrent()
    /// New pictures per second over the last full second (the game's frame rate).
    private(set) var gameFPS = 0

    /// Returns whether `pb` repeats the frame before it.
    func observe(_ pb: CVPixelBuffer) -> Bool {
        let samples = sample(pb)
        defer { previous = samples }
        guard samples.count == previous.count, !samples.isEmpty else { return false }
        var sum = 0
        for i in 0..<samples.count { sum += abs(Int(samples[i]) - Int(previous[i])) }
        let diff = Double(sum) / Double(samples.count)

        // Below a fifth of recent motion (and under a code value) counts as a repeat.
        let isRepeat = diff < min(1.0, max(0.25, motion * 0.2))
        if !isRepeat { motion = motion * 0.9 + diff * 0.1 }
        let still = diff < 0.25 && motion < 0.6  // nothing moving: can't tell repeats from new pictures

        history.append(isRepeat)
        if history.count > 24 { history.removeFirst() }
        if !still && history.count == 24 {
            let repeats = history.filter { $0 }.count
            // Alternating pattern: about half repeats, never two new pictures in a row for long.
            var alternations = 0
            for i in 1..<history.count where history[i] != history[i - 1] { alternations += 1 }
            let looksHalf = repeats >= 9 && repeats <= 15 && alternations >= 16
            if looksHalf != halfRate {
                halfRate = looksHalf
                print("cadence: game looks like \(looksHalf ? "30" : "60") fps")
            }
        }

        framesThisSecond += 1
        if !isRepeat { uniqueThisSecond += 1 }
        let now = CFAbsoluteTimeGetCurrent()
        if now - secondStart >= 1 {
            gameFPS = Int((Double(uniqueThisSecond) / (now - secondStart)).rounded())
            uniqueThisSecond = 0; framesThisSecond = 0; secondStart = now
        }
        return isRepeat
    }

    /// Every 8th luma sample in both directions, as 8-bit values (works for 8- and 10-bit frames).
    private func sample(_ pb: CVPixelBuffer) -> [UInt8] {
        guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return [] }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let wide = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        var out = [UInt8]()
        out.reserveCapacity((w / 8) * (h / 8))
        for y in Swift.stride(from: 4, to: h, by: 8) {
            let row = base + y * stride
            for x in Swift.stride(from: 4, to: w, by: 8) {
                out.append(wide ? UInt8(row.load(fromByteOffset: x * 2, as: UInt16.self) >> 8) : row.load(fromByteOffset: x, as: UInt8.self))
            }
        }
        return out
    }
}
