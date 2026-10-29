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

    private static let serviceLock = NSLock()
    nonisolated(unsafe) private static var cachedVoiceService: String?

    /// The service bb transcribes with ("Codex", "bb cloud"), as last read by `refreshVoiceService()`.
    static var voiceService: String? { serviceLock.withLock { cachedVoiceService } }

    /// Asks bb which voice service it uses. Runs a process: call off the main thread.
    static func refreshVoiceService() {
        let service = loadVoiceService()
        serviceLock.withLock { cachedVoiceService = service }
    }

    private static func loadVoiceService() -> String? {
        guard let location else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: location.executable)
        process.arguments = ["settings", "ai-services", "show"]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("BB_") }
        environment["PATH"] = location.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // "voice           Automatic (using Codex)" or "voice           Codex"
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("voice ") }) else { return nil }
        let value = line.dropFirst("voice".count).trimmingCharacters(in: .whitespaces)
        if let range = value.range(of: "using "), value.hasSuffix(")") {
            return String(value[range.upperBound...].dropLast())
        }
        return value.isEmpty ? nil : value
    }

    private var process: Process?

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish(samples: [Float]) async throws -> String {
        guard let location = Self.location else {
            throw TranscriptionError.unavailable(tr("bb not found", "bb не найден"))
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacevoice-\(UUID().uuidString).wav")
        try Recorder.wav(samples).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // The voice service (Codex) sometimes fails a request outright; one retry usually does it.
        do {
            return try await run(location, file: file)
        } catch TranscriptionError.failed {
            return try await run(location, file: file)
        }
    }

    private func run(_ location: Location, file: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: location.executable)
        process.arguments = ["voice", "transcribe", "--type", "audio/wav", "--json", file.path]
        // Always ask this Mac's bb, however the app was started: drop a launching
        // bb thread's context (BB_SERVER_URL, BB_CLI, …).
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("BB_") }
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
                    let message = error.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { !$0.isEmpty }
                    continuation.resume(throwing: TranscriptionError.failed(
                        "bb: " + (message ?? "exit \(process.terminationStatus)")
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
            throw TranscriptionError.unavailable(tr("No OpenAI key", "Нет ключа OpenAI"))
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
            throw TranscriptionError.unavailable(tr("Apple can't recognize \(locale.identifier)", "Apple не распознаёт язык \(locale.identifier)"))
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

// MARK: - Codex

/// Transcribes with the ChatGPT subscription Codex is signed in with, as bb's Codex provider does.
final class CodexTranscription: Transcription, @unchecked Sendable {
    private var task: Task<String, Error>?

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish(samples: [Float]) async throws -> String {
        guard let account = CodexAccount.credentials() else {
            throw TranscriptionError.unavailable(tr("Sign in to Codex first", "Сначала войдите в Codex"))
        }
        let task = Task {
            let boundary = "SpaceVoice-\(UUID().uuidString)"
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(account.accountID, forHTTPHeaderField: "chatgpt-account-id")
            request.setValue("space_voice", forHTTPHeaderField: "originator")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n".utf8))
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(Recorder.wav(samples))
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.httpBody = body

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            struct Response: Decodable { let text: String }
            switch status {
            case 200:
                return try JSONDecoder().decode(Response.self, from: data).text
            case 401:
                throw TranscriptionError.failed(tr(
                    "Codex sign-in expired — open Codex once to renew it",
                    "Вход в Codex истёк — откройте Codex, чтобы его обновить"
                ))
            default:
                throw TranscriptionError.failed("Codex: HTTP \(status)")
            }
        }
        self.task = task
        return try await task.value
    }

    func cancel() {
        task?.cancel()
    }
}

// MARK: - Claude

/// Streams to the speech-to-text service behind Claude Code's voice mode, with the
/// claude.ai subscription Claude Code is signed in with. Words come back while you talk.
final class ClaudeTranscription: Transcription, @unchecked Sendable {
    /// After CloseStream: give up waiting for the last words after this long…
    private let safetyTimeout: TimeInterval = 5
    /// …or this long without any message.
    private let noDataTimeout: TimeInterval = 1.5

    private let socket: URLSessionWebSocketTask
    private let onPartial: @Sendable (String) -> Void
    private let lock = NSLock()
    private var finals: [String] = []
    private var interim = ""
    private var serverError: String?
    private var closing = false
    private var done = false
    private var lastMessageAt = Date()
    private var keepAlive: Task<Void, Never>?

    init(locale: Locale, onPartial: @escaping @Sendable (String) -> Void) throws {
        guard let account = ClaudeAccount.credentials() else {
            throw TranscriptionError.unavailable(tr("Sign in to Claude Code first", "Сначала войдите в Claude Code"))
        }
        guard !account.isExpired else {
            throw TranscriptionError.unavailable(tr(
                "Claude sign-in expired — open Claude Code once to renew it",
                "Вход в Claude истёк — откройте Claude Code, чтобы его обновить"
            ))
        }
        self.onPartial = onPartial
        var components = URLComponents(string: "wss://api.anthropic.com/api/ws/speech_to_text/voice_stream")!
        components.queryItems = [
            "encoding": "linear16",
            "sample_rate": String(Int(Recorder.format.sampleRate)),
            "channels": "1",
            "endpointing_ms": "300",
            "utterance_end_ms": "1000",
            "language": locale.language.languageCode?.identifier ?? "en",
            "use_conversation_engine": "true",
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        send(.string(#"{"type":"KeepAlive"}"#))
        Task { await receive() }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                self?.send(.string(#"{"type":"KeepAlive"}"#))
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        var pcm = Data(capacity: Int(buffer.frameLength) * 2)
        for index in 0..<Int(buffer.frameLength) {
            var value = Int16(max(-1, min(1, channel[index])) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        send(.data(pcm))
    }

    func finish(samples: [Float]) async throws -> String {
        let closedAt = Date()
        lock.withLock {
            closing = true
            lastMessageAt = closedAt
        }
        send(.string(#"{"type":"CloseStream"}"#))
        while true {
            let (finished, quietFor) = lock.withLock { (done, Date().timeIntervalSince(lastMessageAt)) }
            if finished || Date().timeIntervalSince(closedAt) > safetyTimeout || quietFor > noDataTimeout { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        cancel()
        let (text, error) = lock.withLock { ((finals + [interim]).filter { !$0.isEmpty }.joined(separator: " "), serverError) }
        if text.isEmpty, let error { throw TranscriptionError.failed("Claude: \(error)") }
        return text
    }

    func cancel() {
        keepAlive?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        socket.send(message) { _ in }
    }

    private func receive() async {
        while true {
            guard let message = try? await socket.receive() else {
                lock.withLock {
                    if serverError == nil, !closing {
                        serverError = socket.closeReason.flatMap { String(data: $0, encoding: .utf8) }
                            ?? tr("connection failed", "нет соединения")
                    }
                    done = true
                }
                return
            }
            guard case .string(let text) = message,
                  let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }
            let partial: String? = lock.withLock {
                lastMessageAt = Date()
                switch type {
                case "TranscriptText", "TranscriptInterim":
                    interim = json["data"] as? String ?? interim
                case "TranscriptEndpoint":
                    if !interim.isEmpty { finals.append(interim) }
                    interim = ""
                    if closing { done = true }
                case "TranscriptError", "error":
                    serverError = (json["description"] ?? json["message"] ?? json["error_code"]) as? String ?? type
                    if closing { done = true }
                default:
                    return nil
                }
                return (finals + [interim]).filter { !$0.isEmpty }.joined(separator: " ")
            }
            if let partial { onPartial(partial) }
        }
    }
}
