import AVFoundation
import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let gesture = SpaceGesture()
    private let dictation = DictationController()
    private let mainWindow = MainWindow()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        gesture.delegate = dictation
        dictation.onRecordingChange = { [weak self] recording in self?.setIcon(recording: recording) }

        mainWindow.onRequestAccessibility = { [weak self] in self?.startGesture(prompt: false) }
        startGesture(prompt: false)
        // First launch, or something is missing: show the window rather than only a menu bar icon.
        let microphoneReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !UserDefaults.standard.bool(forKey: "launchedBefore") || !AXIsProcessTrusted() || !microphoneReady {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            mainWindow.show()
        }
        // Warm up bb's location off the main thread so the first dictation is quick.
        DispatchQueue.global(qos: .utility).async { _ = BBTranscription.isAvailable }
    }

    /// Opening the app again (Finder, Spotlight, Dock) shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Installs the Space tap once the Accessibility permission is granted.
    private func startGesture(prompt: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), gesture.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startGesture(prompt: false) }
        }
    }

    private func setIcon(recording: Bool) {
        let image = NSImage(
            systemSymbolName: recording ? "mic.fill" : "mic",
            accessibilityDescription: "Space Voice"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !Settings.enabled
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hint = NSMenuItem(title: "Тапните пробел, затем зажмите пробел и говорите", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(item("Открыть Space Voice…", #selector(openMainWindow)))
        menu.addItem(.separator())

        if !AXIsProcessTrusted() || !gesture.isRunning {
            menu.addItem(item("⚠️ Дать доступ к Универсальному доступу…", #selector(openAccessibility)))
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            menu.addItem(item("⚠️ Дать доступ к микрофону…", #selector(openMicrophone)))
        }

        menu.addItem(item("Включено", #selector(toggleEnabled), checked: Settings.enabled))

        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
           id != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? id
            let excluded = Settings.excludedApps.contains(id)
            let toggle = item("Выключить в «\(name)»", #selector(toggleExcluded(_:)), checked: excluded)
            toggle.representedObject = id
            menu.addItem(toggle)
        }
        menu.addItem(.separator())

        let engines = NSMenu()
        let current = DictationController.currentEngine
        for engine in Engine.allCases {
            let available = DictationController.isAvailable(engine) || engine == .openAI
            let entry = item(engine.title, available ? #selector(chooseEngine(_:)) : nil, checked: engine == current)
            entry.representedObject = engine.rawValue
            engines.addItem(entry)
        }
        engines.addItem(.separator())
        engines.addItem(item(Keychain.openAIKey == nil ? "Ключ OpenAI…" : "Ключ OpenAI ✓…", #selector(editOpenAIKey)))
        let languages = NSMenu()
        for (code, title) in [("ru-RU", "Русский"), ("en-US", "English")] {
            let entry = item(title, #selector(chooseLanguage(_:)), checked: Settings.appleLocale == code)
            entry.representedObject = code
            languages.addItem(entry)
        }
        let language = NSMenuItem(title: "Язык Apple", action: nil, keyEquivalent: "")
        language.submenu = languages
        engines.addItem(language)
        let engineItem = NSMenuItem(title: "Распознавание: \(current.title)", action: nil, keyEquivalent: "")
        engineItem.submenu = engines
        menu.addItem(engineItem)

        menu.addItem(item("Звуки", #selector(toggleSounds), checked: Settings.sounds))
        menu.addItem(item("Запускать при входе", #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "Space Voice \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(item("Выйти", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector?, checked: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func openMainWindow() {
        mainWindow.show()
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        setIcon(recording: false)
    }

    @objc private func toggleExcluded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var apps = Settings.excludedApps
        if apps.remove(id) == nil { apps.insert(id) }
        Settings.excludedApps = apps
    }

    @objc private func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = Engine(rawValue: raw) else { return }
        if engine == .openAI, Keychain.openAIKey == nil {
            editOpenAIKey()
            guard Keychain.openAIKey != nil else { return }
        }
        Settings.engine = engine
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Settings.appleLocale = code
    }

    @objc private func editOpenAIKey() {
        let alert = NSAlert()
        alert.messageText = "Ключ OpenAI API"
        alert.informativeText = "Хранится в связке ключей. Модель: \(Settings.openAIModel). Оставьте пустым, чтобы удалить."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.openAIKey = key.isEmpty ? nil : key
        if key.isEmpty, Settings.engine == .openAI { Settings.engine = nil }
    }

    @objc private func toggleSounds() {
        Settings.sounds.toggle()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        startGesture(prompt: false)
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
