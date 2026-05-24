import AppKit
import ApplicationServices

/// Result of probing the accessibility tree at the cursor to decide whether
/// the hit element is "text-like" enough to be worth running the full
/// `AXWordReader.resolve` pipeline on. Used by `AppDelegate.handleThreeFingerTap`
/// to short-circuit on buttons, images, empty space, and other non-text UI —
/// the LLM round-trip is expensive, and worse, `resolve` on a non-text hit
/// can return a stale word from a nearby text element.
enum TextProbeOutcome {
    /// Role / attributes indicate text content under the cursor. Proceed
    /// with `AXWordReader.resolve(at:)`.
    case text
    /// Role read successfully but the element doesn't look text-like.
    /// The associated diagnostic string is shown in the debug popup so
    /// the user can see what was hit. v0.2.1 retains a compact debug
    /// popup per user instruction; v0.3 may swap this for a true no-op.
    case nonText(String)
    /// The AX call itself failed — typically `AXUIElementCopyElementAtPosition`
    /// returning an error. Diagnostic string captures the failure reason
    /// for the debug popup.
    case failed(String)
}

/// Lightweight role-only probe over the system accessibility hierarchy.
/// This is intentionally cheaper than `AXWordReader.resolve` — we only
/// look at role / character-count attributes on the hit element and a
/// few parents, not the full per-character bounds scan. The probe runs
/// before `resolve` and exists to keep three-finger tap on buttons /
/// images / empty space from kicking off the LLM round-trip (Issue 5).
enum AXTextRoleProbe {
    /// Maximum number of ancestor walks before giving up. WebKit and many
    /// AppKit text views wrap their `AXStaticText` leaf inside an
    /// `AXGroup` / `AXScrollArea` that doesn't expose a text role itself
    /// but does report `kAXNumberOfCharactersAttribute > 0` — the walk
    /// catches that case.
    private static let parentWalkDepth = 3

    /// Roles considered first-class text containers. We accept these
    /// without further attribute probing — they're documented to expose
    /// text content via the standard AX text APIs.
    private static let textRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        kAXComboBoxRole as String
    ]

    /// Probe the accessibility tree at the given AppKit-space point.
    /// Returns `.text` when the cursor sits on text-like content,
    /// `.nonText(role)` when a role was read but doesn't satisfy text
    /// acceptance, `.failed(reason)` on any AX-layer error.
    static func probe(at appKitPoint: CGPoint) -> TextProbeOutcome {
        // Convert AppKit point (origin bottom-left, primary screen) to
        // Quartz point (origin top-left, primary screen). Inline the
        // primary-screen flip rather than reaching into AXWordReader —
        // the helper there is private. Same convention either way.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        guard let primary else {
            return .failed("no primary screen")
        }
        let axPoint = CGPoint(x: appKitPoint.x, y: primary.frame.maxY - appKitPoint.y)

        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &hitElement
        )
        guard hitError == .success, let hit = hitElement else {
            return .failed("AXUIElementCopyElementAtPosition err=\(hitError.rawValue)")
        }

        // Walk hit element + up to `parentWalkDepth` parents looking for
        // ANY level that satisfies acceptance. WebKit `AXGroup` containers
        // hide a text leaf one or two levels up; the AppKit Mail viewer
        // wraps its content in `AXScrollArea`. Either pass acceptance via
        // role match OR via `kAXNumberOfCharactersAttribute > 0`.
        var current: AXUIElement = hit
        var firstRole: String?
        for depth in 0...parentWalkDepth {
            let role = readRole(current)
            if depth == 0 {
                firstRole = role
            }
            if let role, textRoles.contains(role) {
                return .text
            }
            if let count = readNumberOfCharacters(current), count > 0 {
                return .text
            }
            guard let parent = readParent(current) else {
                break
            }
            current = parent
        }

        // No level passed acceptance. Return the hit element's role for
        // the debug popup — that's the most useful signal for the user
        // (they pointed at "AXButton" / "AXImage" / etc.).
        return .nonText(firstRole ?? "unknown")
    }

    // MARK: - AX attribute readers
    //
    // Local copies of the role / parent / character-count readers so this
    // probe doesn't depend on internal AXWordReader helpers. Each one
    // returns nil on any error rather than throwing — non-text outcomes
    // and probe failures are both expected at the call site.

    private static func readRole(_ element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw)
        guard error == .success else { return nil }
        return raw as? String
    }

    private static func readParent(_ element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw)
        guard error == .success, let raw else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func readNumberOfCharacters(_ element: AXUIElement) -> Int? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &raw
        )
        guard error == .success, let raw else { return nil }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        return nil
    }
}
