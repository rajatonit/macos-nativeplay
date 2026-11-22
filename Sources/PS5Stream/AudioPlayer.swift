// Plays the decoded PCM audio from the stream.

import AVFoundation

final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var queued = 0
    private let maxQueued = 8  // ~80 ms; beyond this we drop audio rather than drift behind the picture

    private func configure(channels: Int, rate: Double) -> AVAudioFormat? {
        if let format, Int(format.channelCount) == channels, format.sampleRate == rate { return format }
        guard let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))
        else { return nil }
        engine.stop()
        if node.engine == nil { engine.attach(node) }
        engine.connect(node, to: engine.mainMixerNode, format: f)
        do { try engine.start() } catch {
            print("audio: \(error.localizedDescription)")
            return nil
        }
        node.play()
        format = f
        return f
    }

    /// Called from libchiaki's audio thread with interleaved 16-bit samples.
    func play(pcm: UnsafePointer<Int16>, frames: Int, channels: Int, rate: Double) {
        guard frames > 0, let f = configure(channels: channels, rate: rate) else { return }
        lock.lock()
        let tooMany = queued >= maxQueued
        if !tooMany { queued += 1 }
        lock.unlock()
        if tooMany { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<channels {
            let dst = out[ch]
            for i in 0..<frames { dst[i] = Float(pcm[i * channels + ch]) / 32768 }
        }
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queued -= 1
            self.lock.unlock()
        }
    }
}
