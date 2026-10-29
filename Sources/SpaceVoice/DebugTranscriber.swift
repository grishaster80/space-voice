import AVFoundation

/// Runs an audio file through an engine the way a dictation would (`--transcribe`).
enum DebugTranscriber {
    static func transcribe(file: URL, engine: Engine) async throws -> String {
        let audio = try AVAudioFile(forReading: file)
        guard let input = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              let converter = AVAudioConverter(from: audio.processingFormat, to: Recorder.format)
        else { throw TranscriptionError.failed("Can't read \(file.path)") }
        try audio.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * Recorder.format.sampleRate / audio.processingFormat.sampleRate) + 64
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Recorder.format, frameCapacity: capacity) else {
            throw TranscriptionError.failed("Out of memory")
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: buffer, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        let session: Transcription
        switch engine {
        case .bb: session = BBTranscription()
        case .openAI: session = OpenAITranscription()
        case .apple:
            guard #available(macOS 26.0, *) else { throw TranscriptionError.unavailable("macOS 26") }
            session = try await AppleTranscription(locale: Locale(identifier: Settings.appleLocale)) { _ in }
        }
        session.append(buffer)
        let start = Date()
        let text = try await session.finish(samples: samples)
        FileHandle.standardError.write(Data("[\(engine.rawValue)] \(String(format: "%.2f", Date().timeIntervalSince(start)))s\n".utf8))
        return text
    }
}
