import Foundation

/// Which service turns the recording into text.
enum Engine: String, CaseIterable {
    /// The claude.ai subscription Claude Code is signed in with (Claude Code's voice mode).
    case claude
    /// The ChatGPT subscription Codex is signed in with.
    case codex
    /// `bb voice transcribe`: the voice service chosen in bb.
    case bb
    /// OpenAI's transcription API with the user's own key.
    case openAI
    /// Apple's on-device dictation model (macOS 26+), works offline.
    case apple

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex (ChatGPT)"
        case .bb: return "bb"
        case .openAI: return tr("OpenAI API key", "Ключ OpenAI API")
        case .apple: return tr("Apple, on device", "Apple, на устройстве")
        }
    }
}

/// Language of the app's own interface.
enum UILanguage: String, CaseIterable {
    case system
    case english
    case russian

    var title: String {
        switch self {
        case .system: return tr("Same as macOS", "Как в macOS")
        case .english: return "English"
        case .russian: return "Русский"
        }
    }
}

/// The English or Russian text, whichever the interface is in.
func tr(_ english: String, _ russian: String) -> String {
    Settings.usesRussian ? russian : english
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

    /// The language you dictate in. Claude and Apple need it; the others detect it.
    static var dictationLocale: String {
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

    static var uiLanguage: UILanguage {
        get { defaults.string(forKey: "uiLanguage").flatMap(UILanguage.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "uiLanguage") }
    }

    static var usesRussian: Bool {
        switch uiLanguage {
        case .english: return false
        case .russian: return true
        case .system: return Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
        }
    }

    /// bb's desktop app: it has its own Space Voice plugin with the same gesture.
    static let bbDesktop = "dev.bb.desktop"

    /// Bundle ids of apps where the gesture is off (for example, apps with their own).
    static var excludedApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "excludedApps") ?? [bbDesktop]) }
        set { defaults.set(Array(newValue).sorted(), forKey: "excludedApps") }
    }

    /// Settings saved by earlier versions: turn the gesture off in bb once, as new installs do.
    static func migrate() {
        guard !defaults.bool(forKey: "bbExcludedByDefault") else { return }
        defaults.set(true, forKey: "bbExcludedByDefault")
        excludedApps.insert(bbDesktop)
    }
}
