import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionHelper {
    // MARK: - Screen Recording (primary permission for the OCR pipeline)

    /// Whether the app can capture the screen. The OCR pipeline needs only
    /// this — no Accessibility — to read the word under the cursor.
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system Screen Recording prompt. Returns the current grant
    /// state; macOS may require an app restart after the user toggles it.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Accessibility (only the optional global keyboard shortcut needs it)

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
