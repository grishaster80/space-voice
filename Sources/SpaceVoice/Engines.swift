import Foundation

/// What this Mac offers for each engine: whether it can be used and why.
struct EngineStatus: Identifiable {
    let engine: Engine
    let isAvailable: Bool
    /// What it runs on ("Claude Team subscription · signed in to Claude Code") or what is missing.
    let detail: String

    var id: Engine { engine }
}

enum Engines {
    /// The order engines are picked in when none is chosen: subscriptions first.
    /// Claude is never picked automatically: it needs the user's OK to read Claude Code's sign-in.
    static let preference: [Engine] = [.codex, .bb, .openAI, .apple]

    /// The engine dictation uses: the chosen one, or the first that works here.
    static var current: Engine {
        if let engine = Settings.engine { return engine }
        return preference.first(where: isAvailable) ?? .apple
    }

    static func isAvailable(_ engine: Engine) -> Bool {
        switch engine {
        case .claude: return ClaudeAccount.isSignedIn
        case .codex: return CodexAccount.credentials() != nil
        case .bb: return BBTranscription.isAvailable
        case .openAI: return Keychain.openAIKey != nil
        case .apple:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }

    /// Every engine with what this Mac has for it. Reads keychains and files: call off the main thread.
    static func detect() -> [EngineStatus] {
        Engine.allCases.map(status)
    }

    static func status(_ engine: Engine) -> EngineStatus {
        switch engine {
        case .claude:
            guard ClaudeAccount.isSignedIn else {
                return EngineStatus(engine: engine, isAvailable: false, detail: tr(
                    "Sign in to Claude Code with a Claude subscription to use it",
                    "Войдите в Claude Code с подпиской Claude, чтобы пользоваться"
                ))
            }
            return EngineStatus(engine: engine, isAvailable: true, detail: tr(
                "Your Claude subscription · signed in to Claude Code. macOS asks once to share that sign-in.",
                "Ваша подписка Claude · вход через Claude Code. macOS один раз спросит разрешение на этот вход."
            ))
        case .codex:
            guard let account = CodexAccount.credentials() else {
                return EngineStatus(engine: engine, isAvailable: false, detail: tr(
                    "Sign in to Codex with a ChatGPT plan to use it",
                    "Войдите в Codex с подпиской ChatGPT, чтобы пользоваться"
                ))
            }
            let plan = account.plan.map { "ChatGPT \($0.capitalized)" } ?? "ChatGPT"
            var detail = tr("\(plan) subscription · signed in to Codex", "Подписка \(plan) · вход через Codex")
            if account.isExpired {
                detail += tr(" · sign-in expired, open Codex", " · вход истёк, откройте Codex")
            }
            return EngineStatus(engine: engine, isAvailable: true, detail: detail)
        case .bb:
            guard BBTranscription.isAvailable else {
                return EngineStatus(engine: engine, isAvailable: false, detail: tr("bb isn't installed", "bb не установлен"))
            }
            let service = BBTranscription.voiceService.map { tr(" (now \($0))", " (сейчас \($0))") } ?? ""
            return EngineStatus(engine: engine, isAvailable: true, detail: tr(
                "The voice service chosen in bb\(service)",
                "Сервис голоса, выбранный в bb\(service)"
            ))
        case .openAI:
            return EngineStatus(
                engine: engine,
                isAvailable: Keychain.openAIKey != nil,
                detail: Keychain.openAIKey != nil
                    ? tr("Your key · \(Settings.openAIModel)", "Ваш ключ · \(Settings.openAIModel)")
                    : tr("Add your own key, paid per use", "Добавьте свой ключ, оплата за использование")
            )
        case .apple:
            let available = isAvailable(engine)
            return EngineStatus(
                engine: engine,
                isAvailable: available,
                detail: available
                    ? tr("Offline and free · Russian has no punctuation", "Офлайн и бесплатно · русский без пунктуации")
                    : tr("Needs macOS 26", "Нужна macOS 26")
            )
        }
    }
}
