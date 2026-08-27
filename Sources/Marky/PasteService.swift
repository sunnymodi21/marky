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
        sendPasteViaSystemEvents()
        #else
        sendPasteViaCGEvent()
        #endif
    }

    #if APPSTORE
    private static func sendPasteViaSystemEvents() {
        let source = "tell application \"System Events\" to keystroke \"v\" using command down"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
    #else
    private static func sendPasteViaCGEvent() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    #endif
}
