import AppKit
import ApplicationServices

/// Reads around the caret and types text into whatever field has focus.
@MainActor
enum TextInserter {
    /// Up to `count` characters right before the caret in the focused field, if the app exposes them.
    static func textBeforeCaret(count: Int) -> String? {
        let system = AXUIElementCreateSystemWide()
        if let app = NSWorkspace.shared.frontmostApplication {
            // Chromium and Electron build their accessibility tree only when asked.
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil }
        let start = max(0, selection.location - count)
        var range = CFRange(location: start, length: selection.location - start)
        if range.length == 0 { return "" }
        guard let query = AXValueCreate(.cfRange, &range) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, query, &text
        ) == .success else { return nil }
        return text as? String
    }

    /// Pastes `text` into the focused field, then puts the clipboard back.
    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard managers skip transient items (nspasteboard.org).
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCount = pasteboard.changeCount
        Keyboard.paste()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }
}
