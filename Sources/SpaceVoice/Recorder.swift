import AVFoundation

/// Records the microphone as 16 kHz mono float samples.
final class Recorder: @unchecked Sendable {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    /// Input level 0...1, on the main queue.
    var onLevel: ((Float) -> Void)?
    /// Each converted buffer, on the audio thread. Set before `start()`.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() throws {
        stop()
        lock.withLock { samples = [] }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noMicrophone
        }
        converter = AVAudioConverter(from: inputFormat, to: Self.format)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops recording and returns what was heard.
    @discardableResult
    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        return lock.withLock { samples }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }

        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
        if let onLevel { DispatchQueue.main.async { onLevel(level) } }
        onBuffer?(output)
    }

    /// 16-bit PCM WAV of `samples` at `Recorder.format`'s rate.
    static func wav(_ samples: [Float]) -> Data {
        let rate = UInt32(format.sampleRate)
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian) // PCM
        append(UInt16(1).littleEndian) // mono
        append(rate.littleEndian)
        append((rate * 2).littleEndian) // byte rate
        append(UInt16(2).littleEndian) // block align
        append(UInt16(16).littleEndian) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count).littleEndian)
        data.append(pcm)
        return data
    }
}

enum RecorderError: LocalizedError {
    case noMicrophone

    var errorDescription: String? { "Микрофон не найден" }
}
