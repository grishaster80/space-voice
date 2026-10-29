import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--transcribe"), index + 1 < CommandLine.arguments.count {
    // Debugging: SpaceVoice --transcribe <audio file> [--engine bb|openAI|apple]
    let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let engine = CommandLine.arguments.firstIndex(of: "--engine")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Engine(rawValue: CommandLine.arguments[$0 + 1]) : nil }
    Task {
        do {
            print(try await DebugTranscriber.transcribe(file: file, engine: engine ?? DictationController.currentEngine))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
