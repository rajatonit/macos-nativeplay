// Mac microphone -> PS5 (party/game chat). Delivers 10 ms stereo 16-bit frames at 48 kHz.

import AVFoundation

final class Microphone {
    var onFrame: ((UnsafePointer<Int16>) -> Void)?
    private(set) var running = false
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!
    private var pending: [Int16] = []

    func start() -> Bool {
        if running { return true }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            print("mic: no input device")
            return false
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        do { try engine.start() } catch {
            print("mic: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return false
        }
        running = true
        return true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        pending.removeAll()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let samples = out.int16ChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength) * 2))
        let frame = 480 * 2
        while pending.count >= frame {
            pending.withUnsafeBufferPointer { onFrame?($0.baseAddress!) }
            pending.removeFirst(frame)
        }
    }
}
