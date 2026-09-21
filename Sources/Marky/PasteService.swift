import AppKit
import Carbon.HIToolbox
import Foundation

/// Synthesizes ⌘V into the frontmost app after a history pick.
///
/// Direct-download builds post a CGEvent (Accessibility-gated). The Mac App
/// Store sandbox blocks that, so the App Store build asks System Events via
/// Apple Events instead (Automation permission, prompted on first paste).
@MainActor
enum PasteService {
    static func sendPasteCommand() {
        #if APPSTORE
        sendKeyViaSystemEvents("v")
        #else
        sendCommandKeyViaCGEvent(CGKeyCode(kVK_ANSI_V))
        #endif
    }

    static func sendSelectAllCommand() {
        #if APPSTORE
        sendKeyViaSystemEvents("a")
        #else
        sendCommandKeyViaCGEvent(CGKeyCode(kVK_ANSI_A))
        #endif
    }

    #if APPSTORE
    private static func sendKeyViaSystemEvents(_ key: String) {
        let source = "tell application \"System Events\" to keystroke \"\(key)\" using command down"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
    #else
    private static func sendCommandKeyViaCGEvent(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    #endif
}
