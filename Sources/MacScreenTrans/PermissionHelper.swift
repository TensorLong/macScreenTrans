import AppKit
import ApplicationServices

enum PermissionHelper {
    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func promptForAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openTrackpadSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
