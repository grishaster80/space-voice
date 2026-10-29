import AVFoundation
import Foundation
import Speech

/// One dictation: gets audio while Space is held, then returns the text.
protocol Transcription: AnyObject, Sendable {
    /// Each 16 kHz mono buffer as it is recorded, on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// The transcript of everything recorded (`samples` is the whole recording).
    func finish(samples: [Float]) async throws -> String
    func cancel()
}

enum TranscriptionError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message): return message
        }
    }
}

// MARK: - bb

/// Transcribes with `bb voice transcribe`, the voice service chosen in bb.
final class BBTranscription: Transcription, @unchecked Sendable {
    private struct Location { let executable: String; let path: String }

    /// Where `bb` is, found once through the login shell so a GUI app sees the user's PATH.
    private static let location: Location? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__SPACEVOICE__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf '\\n\(marker)%s\\n\(marker)%s\\n' \"$(command -v bb)\" \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var executable = ""
        var path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if (try? process.run()) != nil {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let values = output.components(separatedBy: "\n")
                .filter { $0.hasPrefix(marker) }
                .map { String($0.dropFirst(marker.count)) }
            if values.count == 2 {
                executable = values[0]
                if !values[1].isEmpty { path = values[1] }
            }
        }
        if executable.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            executable = ["\(home)/.local/bin/bb", "/opt/homebrew/bin/bb", "/usr/local/bin/bb"]
                .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
        }
        return executable.isEmpty ? nil : Location(executable: executable, path: path)
    }()

    static var isAvailable: Bool { location != nil }

    private var process: Process?

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish(samples: [Float]) async throws -> String {
        guard let location = Self.location else {
            throw TranscriptionError.unavailable("bb не найден")
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacevoice-\(UUID().uuidString).wav")
        try Recorder.wav(samples).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: location.executable)
        process.arguments = ["voice", "transcribe", "--type", "audio/wav", "--json", file.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = location.path
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        self.process = process

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                struct Response: Decodable { let text: String }
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CancellationError())
                } else if process.terminationStatus == 0,
                          let response = try? JSONDecoder().decode(Response.self, from: data) {
                    continuation.resume(returning: response.text)
                } else {
                    let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: TranscriptionError.failed(
                        message.isEmpty ? "bb voice transcribe: код \(process.terminationStatus)" : message
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        if process?.isRunning == true { process?.terminate() }
    }
}

// MARK: - OpenAI

/// Transcribes with OpenAI's `/v1/audio/transcriptions`.
final class OpenAITranscription: Transcription, @unchecked Sendable {
    static var isAvailable: Bool { Keychain.openAIKey != nil }

    private var task: Task<String, Error>?

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish(samples: [Float]) async throws -> String {
        guard let key = Keychain.openAIKey else {
            throw TranscriptionError.unavailable("Нет ключа OpenAI")
        }
        let model = Settings.openAIModel
        let task = Task {
            let boundary = "SpaceVoice-\(UUID().uuidString)"
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("model", model)
            field("response_format", "json")
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(Recorder.wav(samples))
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.httpBody = body

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            struct Response: Decodable { let text: String }
            struct Failure: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
            guard status == 200 else {
                let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error.message
                throw TranscriptionError.failed(message ?? "OpenAI: HTTP \(status)")
            }
            return try JSONDecoder().decode(Response.self, from: data).text
        }
        self.task = task
        return try await task.value
    }

    func cancel() {
        task?.cancel()
    }
}

// MARK: - Apple

/// Apple's on-device dictation model (macOS 26+), fed live, so it can show words as they come.
@available(macOS 26.0, *)
final class AppleTranscription: Transcription, @unchecked Sendable {
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<String, Error>?
    private let lock = NSLock()

    /// Prepares the model (downloading it the first time) and starts listening.
    init(locale: Locale, onPartial: @escaping @Sendable (String) -> Void) async throws {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unavailable("Apple не распознаёт язык \(locale.identifier)")
        }
        transcriber = DictationTranscriber(
            locale: supported,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (input, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        if let analyzerFormat, analyzerFormat != Recorder.format {
            converter = AVAudioConverter(from: Recorder.format, to: analyzerFormat)
        }
        let transcriber = transcriber
        resultsTask = Task {
            var final = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    final += text
                    onPartial(final)
                } else {
                    onPartial(final + text)
                }
            }
            return final
        }
        try await analyzer.start(inputSequence: input)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish(samples: [Float]) async throws -> String {
        inputContinuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultsTask?.value ?? ""
    }

    func cancel() {
        inputContinuation.finish()
        resultsTask?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let format = analyzerFormat else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        lock.withLock {
            _ = converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
        }
        return error == nil ? output : nil
    }
}
