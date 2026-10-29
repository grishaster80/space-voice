import AVFoundation
import AppKit

/// Runs one dictation per gesture: microphone, transcription, insertion.
@MainActor
final class DictationController: SpaceGestureDelegate {
    /// Shorter recordings are taken as an accidental hold and dropped.
    private let minimumDuration: TimeInterval = 0.3

    private let recorder = Recorder()
    private let hud = HUD()
    private let feed = Feed()
    private var transcription: Task<Transcription, Error>?
    private var generation = 0

    /// Called when recording starts or stops, for the menu bar icon.
    var onRecordingChange: ((Bool) -> Void)?

    init() {
        recorder.onLevel = { [weak self] level in self?.hud.setLevel(level) }
        let feed = feed
        recorder.onBuffer = { buffer in feed.append(buffer) }
    }

    /// The engine that will be used: the chosen one, or the first that works here.
    nonisolated static var currentEngine: Engine {
        if let engine = Settings.engine { return engine }
        if BBTranscription.isAvailable { return .bb }
        if OpenAITranscription.isAvailable { return .openAI }
        return .apple
    }

    nonisolated static func isAvailable(_ engine: Engine) -> Bool {
        switch engine {
        case .bb: return BBTranscription.isAvailable
        case .openAI: return OpenAITranscription.isAvailable
        case .apple:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }

    // MARK: SpaceGestureDelegate

    func spaceGestureShouldBegin() -> Bool {
        guard Settings.enabled,
              AVCaptureDevice.authorizationStatus(for: .audio) != .denied
        else { return false }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return !Settings.excludedApps.contains(app)
    }

    func spaceGestureDidBeginRecording() {
        generation += 1
        removeFirstTapSpace()
        feed.reset()
        do {
            try recorder.start()
        } catch {
            hud.show(.failed(error.localizedDescription))
            return
        }
        guard recorder.isRunning else {
            hud.show(.failed(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                ? tr("Couldn't start the microphone", "Не удалось включить микрофон")
                : tr("No microphone access", "Нет доступа к микрофону")))
            return
        }
        if Settings.sounds { NSSound(named: "Tink")?.play() }
        onRecordingChange?(true)
        hud.show(.listening)
        transcription = makeTranscription(generation: generation)
    }

    func spaceGestureDidEndRecording() {
        onRecordingChange?(false)
        let samples = recorder.stop()
        guard let transcription else { return }
        self.transcription = nil
        let current = generation
        let duration = Double(samples.count) / Recorder.format.sampleRate
        guard duration >= minimumDuration else {
            Task { try? await transcription.value.cancel() }
            feed.reset()
            hud.hide()
            return
        }
        if Settings.sounds { NSSound(named: "Pop")?.play() }
        hud.show(.transcribing)
        Task {
            do {
                let text = try await transcribe(samples, with: transcription)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if current == generation { hud.hide() }
                if !text.isEmpty { TextInserter.insert(text) }
            } catch is CancellationError {
                if current == generation { hud.hide() }
            } catch {
                Self.saveFailedRecording(samples)
                if current == generation { hud.show(.failed(error.localizedDescription)) }
            }
        }
    }

    /// The transcript from the chosen engine, or from Apple's on-device model when
    /// that engine fails, so a dictation is not lost to a network or service error.
    private func transcribe(_ samples: [Float], with transcription: Task<Transcription, Error>) async throws -> String {
        let session = try await transcription.value
        do {
            return try await session.finish(samples: samples)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard #available(macOS 26.0, *), !(session is AppleTranscription) else { throw error }
            hud.setText(tr("Failed, retrying on device…", "Не вышло, распознаю на устройстве…"))
            let fallback = try await AppleTranscription(locale: Locale(identifier: Settings.appleLocale)) { _ in }
            if let buffer = Recorder.buffer(samples) { fallback.append(buffer) }
            return try await fallback.finish(samples: samples)
        }
    }

    /// Keeps the last recording that could not be transcribed, to retry or debug it.
    private static func saveFailedRecording(_ samples: [Float]) {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.grishaster80.spacevoice")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Recorder.wav(samples).write(to: directory.appendingPathComponent("last-failed.wav"))
    }

    func spaceGestureDidCancelRecording() {
        onRecordingChange?(false)
        recorder.stop()
        let transcription = transcription
        self.transcription = nil
        Task { try? await transcription?.value.cancel() }
        feed.reset()
        hud.hide()
    }

    // MARK: Private

    /// The first tap typed a space. Keep it when it separates the dictation from
    /// a word before it; otherwise delete it, as the Space Voice plugin does.
    private func removeFirstTapSpace() {
        guard let before = TextInserter.textBeforeCaret(count: 2) else {
            Keyboard.press(Keyboard.delete)
            return
        }
        guard before.last == " " || before.last == "\u{00A0}" else { return }
        if before.count == 2, let previous = before.first, !previous.isWhitespace { return }
        Keyboard.press(Keyboard.delete)
    }

    private func makeTranscription(generation: Int) -> Task<Transcription, Error> {
        let engine = Self.currentEngine
        let feed = feed
        return Task {
            let session: Transcription
            switch engine {
            case .bb:
                guard BBTranscription.isAvailable else {
                    throw TranscriptionError.unavailable(tr("bb not found — choose another engine", "bb не найден — выберите другое распознавание"))
                }
                session = BBTranscription()
            case .openAI:
                guard OpenAITranscription.isAvailable else {
                    throw TranscriptionError.unavailable(tr("Add an OpenAI key in Space Voice", "Добавьте ключ OpenAI в Space Voice"))
                }
                session = OpenAITranscription()
            case .apple:
                guard #available(macOS 26.0, *) else {
                    throw TranscriptionError.unavailable(tr("Apple transcription needs macOS 26", "Распознавание Apple требует macOS 26"))
                }
                let locale = Locale(identifier: Settings.appleLocale)
                session = try await AppleTranscription(locale: locale) { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        self.hud.setText(text)
                    }
                }
            }
            feed.attach(session)
            return session
        }
    }
}

/// Hands recorded buffers to the transcription, keeping them until it is ready.
private final class Feed: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var session: Transcription?

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if let session {
                session.append(buffer)
            } else {
                pending.append(buffer)
            }
        }
    }

    func attach(_ session: Transcription) {
        lock.withLock {
            for buffer in pending { session.append(buffer) }
            pending = []
            self.session = session
        }
    }

    func reset() {
        lock.withLock {
            pending = []
            session = nil
        }
    }
}
