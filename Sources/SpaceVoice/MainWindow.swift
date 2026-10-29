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
    @Published var engine = DictationController.currentEngine
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var hasOpenAIKey = Keychain.openAIKey != nil
    @Published var language = Settings.uiLanguage
    @Published var excludedApps: [ExcludedApp] = []

    var onRequestAccessibility: (() -> Void)?
    private var timer: Timer?

    func refresh() {
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        enabled = Settings.enabled
        engine = DictationController.currentEngine
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hasOpenAIKey = Keychain.openAIKey != nil
        language = Settings.uiLanguage
        excludedApps = Settings.excludedApps.map(ExcludedApp.init(bundleID:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func startRefreshing() {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Space Voice").font(.title2.bold())
                    Text(status).foregroundStyle(ready && model.enabled ? .green : .orange)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    permission(
                        tr("Accessibility", "Универсальный доступ"),
                        detail: tr("to hear Space and insert text", "чтобы слышать пробел и вставлять текст"),
                        granted: model.accessibility,
                        action: model.grantAccessibility
                    )
                    Divider()
                    permission(
                        tr("Microphone", "Микрофон"),
                        detail: tr("listens only while you hold Space", "слушает, только пока держите пробел"),
                        granted: model.microphone == .authorized,
                        action: model.grantMicrophone
                    )
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(tr("How to use", "Как пользоваться")).font(.headline)
                Text(LocalizedStringKey(tr(
                    "Put the cursor in any text field, **tap Space**, then **press and hold Space** and talk. Release it and the text is inserted. `Esc` cancels.",
                    "Поставьте курсор в любое поле, **тапните пробел**, затем **зажмите пробел** и говорите. Отпустите — текст вставится. `Esc` — отменить."
                )))
                .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Toggle(tr("Enabled", "Включено"), isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                Picker(tr("Transcription", "Распознавание"), selection: Binding(get: { model.engine }, set: model.setEngine)) {
                    ForEach(Engine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.engine == .openAI {
                    Button(tr("OpenAI Key…", "Ключ OpenAI…"), action: model.editOpenAIKey)
                }
                Picker(tr("Language", "Язык"), selection: Binding(get: { model.language }, set: model.setLanguage)) {
                    ForEach(UILanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(tr("Open at login", "Запускать при входе"), isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
            }
            .formStyle(.columns)

            excludedApps

            Text(tr(
                "More options are in the microphone icon in the menu bar. If the notch hides it, just open the app again.",
                "Остальное — в иконке микрофона в строке меню. Если её не видно за вырезом экрана, просто откройте приложение снова."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 480)
    }

    private var excludedApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Turned off in", "Выключено в")).font(.headline)
                Spacer()
                Menu(tr("Add App", "Добавить")) {
                    ForEach(model.runningApps) { app in
                        Button {
                            model.exclude(app.id)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        }
                    }
                    Divider()
                    Button(tr("Choose…", "Выбрать…"), action: model.chooseAppToExclude)
                }
                .fixedSize()
            }
            if model.excludedApps.isEmpty {
                Text(tr("Works in every app.", "Работает во всех приложениях."))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.excludedApps) { app in
                        HStack {
                            Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                            Text(app.name)
                            if app.id == Settings.bbDesktop {
                                Text(tr("has its own Space Voice", "там свой Space Voice"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.include(app.id)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(tr("Turn back on", "Включить обратно"))
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        if app.id != model.excludedApps.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }

    private var ready: Bool { model.accessibility && model.microphone == .authorized }

    private var status: String {
        if !ready { return tr("Needs the permissions below", "Нужны разрешения ниже") }
        return model.enabled
            ? tr("Ready — works in any text field", "Готово — работает в любом поле")
            : tr("Turned off", "Выключено")
    }

    private func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button(tr("Allow…", "Разрешить…"), action: action) }
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
