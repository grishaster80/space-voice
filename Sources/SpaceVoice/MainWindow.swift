import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The window shown when the app is opened: permissions, how to use it, settings.
/// The app otherwise lives in the menu bar, where the notch can hide its icon.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = MainWindowModel()

    /// Called when Accessibility access may have just been granted.
    var onRequestAccessibility: (() -> Void)?

    func show() {
        model.onRequestAccessibility = { [weak self] in self?.onRequestAccessibility?() }
        model.refresh()
        if window == nil {
            let controller = NSHostingController(rootView: MainView(model: model))
            controller.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: controller)
            window.title = "Space Voice"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.startRefreshing()
        // A window of a menu bar app needs a Dock icon to come to the front reliably.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Development: renders the window to a PNG (`SpaceVoice --snapshot <path> [expanded]`).
    func snapshot(to url: URL, expanded: Bool) {
        model.expandAll = expanded
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let view = self.window?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            exit(0)
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRefreshing()
        NSApp.setActivationPolicy(.accessory)
    }
}

/// An app the gesture is turned off in.
struct ExcludedApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    init(bundleID: String) {
        id = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            name = bundleID
            icon = NSWorkspace.shared.icon(for: .application)
        }
    }
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var accessibility = false
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var enabled = Settings.enabled
    @Published var engine = Engines.current
    @Published var engines: [EngineStatus] = []
    @Published var dictationLocale = Settings.dictationLocale
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var hasOpenAIKey = Keychain.openAIKey != nil
    @Published var language = Settings.uiLanguage
    @Published var excludedApps: [ExcludedApp] = []
    /// Development: open every section (for `--snapshot`).
    var expandAll = false

    var onRequestAccessibility: (() -> Void)?
    private var timer: Timer?

    func refresh() {
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        enabled = Settings.enabled
        engine = Engines.current
        engines = Engines.detect()
        dictationLocale = Settings.dictationLocale
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hasOpenAIKey = Keychain.openAIKey != nil
        language = Settings.uiLanguage
        excludedApps = Settings.excludedApps.map(ExcludedApp.init(bundleID:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func startRefreshing() {
        // bb's voice service comes from running bb: read it in the background.
        DispatchQueue.global(qos: .userInitiated).async {
            BBTranscription.refreshVoiceService()
            DispatchQueue.main.async { self.refresh() }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasTrusted = self.accessibility
                self.accessibility = AXIsProcessTrusted()
                self.microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                if !wasTrusted, self.accessibility { self.onRequestAccessibility?() }
            }
        }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    func grantAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        onRequestAccessibility?()
    }

    func grantMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.refresh() }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func setEnabled(_ value: Bool) {
        Settings.enabled = value
        refresh()
    }

    func setEngine(_ value: Engine) {
        if value == .openAI, Keychain.openAIKey == nil {
            OpenAIKeyPrompt.run()
            guard Keychain.openAIKey != nil else { return refresh() }
        }
        Settings.engine = value
        refresh()
    }

    func setDictationLocale(_ value: String) {
        Settings.dictationLocale = value
        refresh()
    }

    func setLanguage(_ value: UILanguage) {
        Settings.uiLanguage = value
        refresh()
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    func editOpenAIKey() {
        OpenAIKeyPrompt.run()
        refresh()
    }

    /// Running apps with a window that are not excluded yet, for the Add menu.
    var runningApps: [ExcludedApp] {
        let excluded = Settings.excludedApps
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !excluded.contains($0) && $0 != Bundle.main.bundleIdentifier }
        return Set(ids).map(ExcludedApp.init(bundleID:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func exclude(_ bundleID: String) {
        Settings.excludedApps.insert(bundleID)
        refresh()
    }

    func include(_ bundleID: String) {
        Settings.excludedApps.remove(bundleID)
        refresh()
    }

    func chooseAppToExclude() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = tr("Turn Off", "Выключить")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { Settings.excludedApps.insert(id) }
        }
        refresh()
    }
}

private struct MainView: View {
    @ObservedObject var model: MainWindowModel

    @State private var showEngines = false
    @State private var showExcluded = false
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !ready { permissions }
            VStack(spacing: 0) {
                section(tr("Transcription", "Распознавание"), value: model.engine.title, isExpanded: $showEngines) {
                    engines
                }
                Divider()
                section(tr("Turned off in", "Выключено в"), value: excludedSummary, isExpanded: $showExcluded) {
                    excludedApps
                }
                Divider()
                section(tr("Settings", "Настройки"), value: settingsSummary, isExpanded: $showSettings) {
                    settings
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .padding(16)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.15), value: showEngines)
        .animation(.easeOut(duration: 0.15), value: showExcluded)
        .animation(.easeOut(duration: 0.15), value: showSettings)
        .onAppear {
            if model.expandAll { showEngines = true; showExcluded = true; showSettings = true }
        }
    }

    /// A one-line row showing the current value; click it to show the controls.
    private func section<Content: View>(
        _ title: String,
        value: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    .frame(width: 12)
                Text(title)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.wrappedValue.toggle() }
            if isExpanded.wrappedValue {
                content()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
    }

    private var excludedSummary: String {
        model.excludedApps.isEmpty
            ? tr("none", "нигде")
            : model.excludedApps.map(\.name).joined(separator: ", ")
    }

    private var settingsSummary: String {
        var parts = [model.language == .system ? tr("System language", "Язык системы") : model.language.title]
        if model.launchAtLogin { parts.append(tr("opens at login", "при входе")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Space Voice").font(.title3.bold())
                    Text(status).font(.callout).foregroundStyle(ready && model.enabled ? .green : .orange)
                }
                .fixedSize()
                Spacer(minLength: 12)
                Toggle(tr("Enabled", "Включено"), isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(tr("Turn Space Voice on or off", "Включить или выключить Space Voice"))
            }
            Text(LocalizedStringKey(tr(
                "**Tap Space**, then **hold Space** and talk. Release to insert, `Esc` cancels.",
                "**Тапните пробел**, затем **зажмите** и говорите. Отпустите — вставится, `Esc` — отмена."
            )))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissions: some View {
        HStack(spacing: 16) {
            permission(tr("Accessibility", "Универсальный доступ"), granted: model.accessibility,
                       help: tr("To hear Space and insert text", "Чтобы слышать пробел и вставлять текст"),
                       action: model.grantAccessibility)
            permission(tr("Microphone", "Микрофон"), granted: model.microphone == .authorized,
                       help: tr("Listens only while you hold Space", "Слушает, только пока держите пробел"),
                       action: model.grantMicrophone)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))
    }

    private func permission(_ title: String, granted: Bool, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            if !granted { Button(tr("Allow…", "Разрешить…"), action: action).controlSize(.small) }
        }
        .help(help)
    }

    private var ready: Bool { model.accessibility && model.microphone == .authorized }

    private var status: String {
        if !ready { return tr("Needs permissions", "Нужны разрешения") }
        return model.enabled ? tr("Ready", "Готово") : tr("Turned off", "Выключено")
    }

    // MARK: Transcription

    private var engines: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                ForEach(model.engines) { status in
                    engineRow(status)
                    if status.engine != model.engines.last?.engine { Divider().padding(.leading, 30) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            if model.engine == .claude || model.engine == .apple {
                HStack {
                    Text(tr("I speak", "Я говорю")).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { model.dictationLocale }, set: model.setDictationLocale)) {
                        ForEach(AppDelegate.dictationLanguages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .controlSize(.small)
            }
        }
    }

    private func engineRow(_ status: EngineStatus) -> some View {
        let selected = status.engine == model.engine
        return HStack(spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(status.engine.title).fontWeight(selected ? .semibold : .regular)
                    if status.isAvailable, status.engine != .openAI, status.engine != .apple {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                            .help(tr("Found on this Mac", "Найдено на этом Mac"))
                    }
                }
                Text(status.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(status.detail)
            Spacer(minLength: 4)
            if status.engine == .openAI {
                Button(model.hasOpenAIKey ? tr("Change…", "Сменить…") : tr("Add Key…", "Добавить…"),
                       action: model.editOpenAIKey)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .opacity(status.isAvailable ? 1 : 0.55)
        .onTapGesture {
            if status.isAvailable || status.engine == .openAI { model.setEngine(status.engine) }
        }
    }

    // MARK: Settings

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text(tr("Interface", "Интерфейс")).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { model.language }, set: model.setLanguage)) {
                    ForEach(UILanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Toggle(tr("Open at login", "Запускать при входе"),
                       isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
            }
        }
        .controlSize(.small)
    }

    // MARK: Excluded apps

    private var excludedApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("The Space gesture does nothing in these apps.", "В этих приложениях жест пробела не работает."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(model.runningApps) { app in
                        Button {
                            model.exclude(app.id)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        }
                    }
                    Divider()
                    Button(tr("Choose…", "Выбрать…"), action: model.chooseAppToExclude)
                } label: {
                    Text(tr("Add App", "Добавить"))
                }
                .controlSize(.small)
                .fixedSize()
            }
            if model.excludedApps.isEmpty {
                Text(tr("Works in every app.", "Работает во всех приложениях."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.excludedApps) { app in
                        HStack(spacing: 6) {
                            Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Button {
                                model.include(app.id)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(tr("Turn back on", "Включить обратно"))
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .help(app.id == Settings.bbDesktop ? tr("bb has its own Space Voice", "В bb свой Space Voice") : app.name)
                        if app.id != model.excludedApps.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }
}

/// Asks for the OpenAI API key and keeps it in the keychain.
@MainActor
enum OpenAIKeyPrompt {
    static func run() {
        let alert = NSAlert()
        alert.messageText = tr("OpenAI API Key", "Ключ OpenAI API")
        alert.informativeText = tr(
            "Kept in your keychain. Model: \(Settings.openAIModel). Leave empty to remove it.",
            "Хранится в связке ключей. Модель: \(Settings.openAIModel). Оставьте пустым, чтобы удалить."
        )
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-…"
        alert.accessoryView = field
        alert.addButton(withTitle: tr("Save", "Сохранить"))
        alert.addButton(withTitle: tr("Cancel", "Отмена"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.openAIKey = key.isEmpty ? nil : key
        if key.isEmpty, Settings.engine == .openAI { Settings.engine = nil }
    }
}
