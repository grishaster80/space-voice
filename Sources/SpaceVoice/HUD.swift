import AppKit
import SwiftUI

/// The pill at the bottom of the screen that shows dictation is on.
@MainActor
final class HUD {
    enum Phase: Equatable {
        case preparing
        case listening
        case transcribing
        case failed(String)
    }

    final class Model: ObservableObject {
        @Published var phase = Phase.listening
        @Published var level: Float = 0
        @Published var text = ""
    }

    private let model = Model()
    private var hideWork: DispatchWorkItem?
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }()

    func show(_ phase: Phase) {
        hideWork?.cancel()
        if phase == .listening || phase == .preparing, model.phase != .listening {
            model.text = ""
            model.level = 0
        }
        model.phase = phase
        position()
        panel.orderFrontRegardless()
        if case .failed = phase { hide(after: 2.5) }
    }

    func setLevel(_ level: Float) {
        model.level = model.level * 0.5 + level * 0.5
    }

    func setText(_ text: String) {
        model.text = text
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Bottom centre of the screen with the pointer, above the Dock.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 48))
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUD.Model

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(model.text.isEmpty ? 0.75 : 1))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .frame(maxWidth: 420, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.08), value: model.level)
    }

    private var label: String {
        switch model.phase {
        case .preparing: return "Готовлю распознавание…"
        case .listening: return model.text.isEmpty ? "Говорите… отпустите пробел" : model.text
        case .transcribing: return model.text.isEmpty ? "Распознаю…" : model.text
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .listening:
            ZStack {
                Circle().fill(.red.opacity(0.35)).frame(width: 26, height: 26)
                    .scaleEffect(0.6 + CGFloat(model.level) * 0.7)
                Image(systemName: "mic.fill").foregroundStyle(.white).font(.system(size: 13))
            }
            .frame(width: 26, height: 26)
        case .preparing, .transcribing:
            ProgressView().controlSize(.small).tint(.white).frame(width: 26, height: 26)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                .frame(width: 26, height: 26)
        }
    }
}
