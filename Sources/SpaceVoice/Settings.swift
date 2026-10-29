import Foundation

/// Which service turns the recording into text.
enum Engine: String, CaseIterable {
    /// `bb voice transcribe`: the voice service chosen in bb (Codex or bb cloud).
    case bb
    /// OpenAI's transcription API with the user's own key.
    case openAI
    /// Apple's on-device dictation model (macOS 26+), works offline.
    case apple

    var title: String {
        switch self {
        case .bb: return "BB (как в BB)"
        case .openAI: return "OpenAI"
        case .apple: return "Apple, на устройстве"
        }
    }
}

/// User preferences, kept in UserDefaults.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// The chosen engine, or nil to pick the first available one.
    static var engine: Engine? {
        get { defaults.string(forKey: "engine").flatMap(Engine.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: "engine") }
    }

    /// Locale for Apple's on-device engine; the others detect the language.
    static var appleLocale: String {
        get { defaults.string(forKey: "appleLocale") ?? "ru-RU" }
        set { defaults.set(newValue, forKey: "appleLocale") }
    }

    static var openAIModel: String {
        get { defaults.string(forKey: "openAIModel") ?? "gpt-4o-transcribe" }
        set { defaults.set(newValue, forKey: "openAIModel") }
    }

    static var sounds: Bool {
        get { defaults.object(forKey: "sounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sounds") }
    }

    /// Bundle ids of apps where the gesture is off (for example, apps with their own).
    static var excludedApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedApps") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "excludedApps") }
    }
}
