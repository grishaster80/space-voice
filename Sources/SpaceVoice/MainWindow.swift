import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

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
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Space Voice"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: MainView(model: model))
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

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var accessibility = false
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var enabled = Settings.enabled
    @Published var engine = DictationController.currentEngine
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var hasOpenAIKey = Keychain.openAIKey != nil

    var onRequestAccessibility: (() -> Void)?
    private var timer: Timer?

    func refresh() {
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        enabled = Settings.enabled
        engine = DictationController.currentEngine
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hasOpenAIKey = Keychain.openAIKey != nil
    }

    func startRefreshing() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasTrusted = self.accessibility
                self.refresh()
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
        if value == .openAI, Keychain.openAIKey == nil { return }
        Settings.engine = value
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
}

private struct MainView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Space Voice").font(.title2.bold())
                    Text(status).foregroundStyle(ready ? .green : .orange)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    permission(
                        "Универсальный доступ",
                        detail: "чтобы слышать пробел и вставлять текст",
                        granted: model.accessibility,
                        action: model.grantAccessibility
                    )
                    Divider()
                    permission(
                        "Микрофон",
                        detail: "слушает, только пока держите пробел",
                        granted: model.microphone == .authorized,
                        action: model.grantMicrophone
                    )
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Как пользоваться").font(.headline)
                Text("Поставьте курсор в любое поле, **тапните пробел**, затем **зажмите пробел** и говорите. Отпустите — текст вставится. `Esc` — отменить.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Toggle("Включено", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                Picker("Распознавание", selection: Binding(get: { model.engine }, set: model.setEngine)) {
                    ForEach(Engine.allCases, id: \.self) { engine in
                        Text(engine.title + (engine == .openAI && !model.hasOpenAIKey ? " (ключ в меню)" : ""))
                            .tag(engine)
                    }
                }
                Toggle("Запускать при входе", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
            }
            .formStyle(.columns)

            Text("Остальные настройки — в иконке микрофона в строке меню. Если её не видно за вырезом экрана, просто откройте приложение снова.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 460)
    }

    private var ready: Bool { model.accessibility && model.microphone == .authorized }

    private var status: String {
        if !ready { return "Нужны разрешения ниже" }
        return model.enabled ? "Готово — работает в любом поле" : "Выключено"
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
            if !granted { Button("Разрешить…", action: action) }
        }
    }
}
