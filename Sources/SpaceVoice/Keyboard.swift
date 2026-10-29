import CoreGraphics

/// Posts synthetic key presses. They carry `marker` so `SpaceGesture` lets them through.
enum Keyboard {
    static let marker: Int64 = 0x5356_4F49 // "SVOI"

    static let space: CGKeyCode = 49
    static let delete: CGKeyCode = 51
    static let escape: CGKeyCode = 53
    static let v: CGKeyCode = 9

    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = marker
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        return source
    }()

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: marker)
            event?.post(tap: .cghidEventTap)
        }
    }

    static func paste() {
        press(v, flags: .maskCommand)
    }
}
