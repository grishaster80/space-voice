import CoreGraphics
import Foundation

/// What the gesture asks the app to do.
@MainActor
protocol SpaceGestureDelegate: AnyObject {
    /// Whether a second press may turn into dictation here (enabled, app not excluded).
    func spaceGestureShouldBegin() -> Bool
    /// The second press has been held long enough: dictation is on.
    func spaceGestureDidBeginRecording()
    /// Space was released: stop and insert the transcript.
    func spaceGestureDidEndRecording()
    /// Escape while recording: stop and throw the recording away.
    func spaceGestureDidCancelRecording()
}

/// Tap Space, then press and hold Space anywhere to talk, as in bb's Space Voice plugin.
///
/// A global event tap watches Space. The second press is swallowed; held for
/// `holdDelay` it starts dictation, released sooner it is replayed as a normal
/// space, so a quick double tap still types two spaces.
@MainActor
final class SpaceGesture {
    /// The second press must come this soon after the first tap is released.
    private let tapWindow: TimeInterval = 0.4
    /// A first press held longer than this is not a tap.
    private let maxTapDuration: TimeInterval = 0.3
    /// How long the second press must be held before dictation starts.
    private let holdDelay: TimeInterval = 0.2

    private enum State {
        case idle
        case holding(DispatchWorkItem)
        case recording
    }

    weak var delegate: SpaceGestureDelegate?

    private var state = State.idle
    private var firstDownAt: TimeInterval?
    private var lastTapUpAt: TimeInterval?
    private var tap: CFMachPort?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Installs the event tap. Fails without the Accessibility permission.
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: spaceGestureCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown, .keyUp:
            break
        default:
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Keyboard.marker { return pass }

        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let now = TimeInterval(event.timestamp) / 1_000_000_000
        return type == .keyDown ? keyDown(key, event: event, at: now) : keyUp(key, event: event, at: now)
    }

    private func keyDown(_ key: CGKeyCode, event: CGEvent, at now: TimeInterval) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if key == Keyboard.escape, case .recording = state {
            state = .idle
            notify { $0.spaceGestureDidCancelRecording() }
            return nil
        }
        guard key == Keyboard.space, isPlain(event) else {
            firstDownAt = nil
            lastTapUpAt = nil
            return pass
        }
        guard case .idle = state else { return nil }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return pass }

        if let lastTapUpAt, now - lastTapUpAt <= tapWindow, delegate?.spaceGestureShouldBegin() == true {
            self.lastTapUpAt = nil
            let work = DispatchWorkItem { [weak self] in self?.holdElapsed() }
            state = .holding(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
            return nil
        }
        firstDownAt = now
        return pass
    }

    private func keyUp(_ key: CGKeyCode, event: CGEvent, at now: TimeInterval) -> Unmanaged<CGEvent>? {
        guard key == Keyboard.space else { return Unmanaged.passUnretained(event) }
        switch state {
        case .holding(let work):
            // Released too soon: it was just a second space.
            work.cancel()
            state = .idle
            Keyboard.press(Keyboard.space)
            return nil
        case .recording:
            state = .idle
            notify { $0.spaceGestureDidEndRecording() }
            return nil
        case .idle:
            if isPlain(event), let firstDownAt, now - firstDownAt <= maxTapDuration {
                lastTapUpAt = now
            } else {
                lastTapUpAt = nil
            }
            firstDownAt = nil
            return Unmanaged.passUnretained(event)
        }
    }

    private func holdElapsed() {
        guard case .holding = state else { return }
        state = .recording
        delegate?.spaceGestureDidBeginRecording()
    }

    /// Tells the delegate after the tap callback returns: a slow callback delays
    /// every key press, and macOS disables taps that take too long.
    private func notify(_ body: @escaping (SpaceGestureDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let delegate = self?.delegate { body(delegate) }
        }
    }

    private func isPlain(_ event: CGEvent) -> Bool {
        event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }
}

private func spaceGestureCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let gesture = Unmanaged<SpaceGesture>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { gesture.handle(type: type, event: event) }
}
