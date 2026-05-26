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
    /// Associated string is the leaf element's role, for the popup header.
    /// The full per-depth trace is in `AXTextRoleProbe.lastTrace`.
    case nonText(String)
    /// The AX call itself failed — typically `AXUIElementCopyElementAtPosition`
    /// returning an error. Diagnostic string captures the failure reason.
    case failed(String)
}

/// Role-only probe over the system accessibility hierarchy. Cheaper than
/// `AXWordReader.resolve` — only inspects role / subrole / value / chars on
/// the hit element and a few parents. Exists to short-circuit on buttons /
/// images / empty space before kicking off the LLM round-trip.
///
/// v0.2.3 widening (vs. v0.2.2):
///   - Accept `kAXValueAttribute` as a non-empty String. Native AppKit text
///     (NSTextField labels, NSTextView, NSTableCellView text, NSPathControl
///     segments) reliably sets `kAXValue` to a String but does NOT always
///     set `kAXNumberOfCharactersAttribute`. The v0.2.2 probe over-rejected
///     these targets so only WebKit (Chrome/Safari/Mail HTML) worked.
///     The `as? String` cast self-filters numeric values (slider/checkbox/
///     progress indicator return NSNumber/NSBoolean — they fail the cast).
///   - Add hard-exclude role list so AXButton / AXPopUpButton / AXMenuButton
///     are rejected even when they expose a String title via `kAXValue`.
///     Otherwise tapping a "Save" button would translate "Save" — false
///     positive that defeats Issue 5's purpose.
///   - Accept title-bearing roles (Link, MenuItem) via `kAXTitleAttribute`.
///   - Bump parent walk depth from 3 to 4 to match `AXWordReader`'s
///     `resolveTextElementAndRange` walk depth.
///   - Capture full per-depth trace in `lastTrace` so the rejection popup
///     can show exactly what was probed (role / subrole / chars / value /
///     title at each level) — debugging without a code change next time.
enum AXTextRoleProbe {
    /// Maximum number of ancestor walks before giving up. WebKit and many
    /// AppKit text views wrap their `AXStaticText` leaf inside an
    /// `AXGroup` / `AXScrollArea` that doesn't expose a text role itself
    /// but does report `kAXNumberOfCharactersAttribute > 0` — the walk
    /// catches that case. Matched to `AXWordReader.resolveTextElementAndRange`.
    private static let parentWalkDepth = 4

    /// Roles considered first-class text containers. Accept without
    /// inspecting attributes.
    private static let textRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        kAXComboBoxRole as String,
        // WebKit emits "AXHeading" for <h1>-<h6>. Not in HIServices role
        // constants; use the literal string.
        "AXHeading"
    ]

    /// Roles whose textual content lives in `kAXTitleAttribute`, not
    /// `kAXValueAttribute`. Accept when title is non-empty.
    private static let titleBearingRoles: Set<String> = [
        // "AXLink" is not exposed as a `kAXLinkRole` constant in
        // HIServices (only in AppKit's NSAccessibilityRole namespace);
        // the underlying CFString value is the literal "AXLink".
        "AXLink",
        kAXMenuItemRole as String,
        kAXMenuBarItemRole as String
    ]

    /// AX parameterized text attributes that the resolver in `AXWordReader`
    /// actually calls. An element advertising any of these in
    /// `AXUIElementCopyParameterizedAttributeNames` is exposing the macOS
    /// text-selection / copy contract — that's the strongest AX-layer
    /// projection of the user's "selectable + copyable ⇄ must work"
    /// principle. v0.2.4 widening for Terminal.app / iTerm2 / custom
    /// text views that don't expose `kAXValue` as a String but DO
    /// implement the parameterized text API.
    private static let textParameterizedAttributes: Set<String> = [
        kAXStringForRangeParameterizedAttribute as String,
        kAXRangeForPositionParameterizedAttribute as String,
        kAXBoundsForRangeParameterizedAttribute as String
    ]

    /// Non-parameterized text attribute. Selected-text being available is
    /// also a strong signal — selection requires text content.
    private static let textApiAttributes: Set<String> = [
        kAXSelectedTextAttribute as String
    ]

    /// Roles to HARD-EXCLUDE even when they have a String value/title.
    /// Without this filter, tapping a "Save" button or a popup menu's
    /// selection title would translate it — Issue 5 false positive.
    private static let nonTextRoles: Set<String> = [
        kAXButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuButtonRole as String,
        kAXImageRole as String,
        kAXSliderRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXProgressIndicatorRole as String,
        kAXValueIndicatorRole as String,
        kAXIncrementorRole as String,
        kAXScrollBarRole as String
    ]

    /// Per-depth trace from the most recent `probe(at:)` call, for the
    /// rejection popup. Reset on every call. Treat as advisory; reads
    /// from anywhere are safe because the writer thread is the AppDelegate
    /// main thread that drives the user's three-finger-tap handler.
    nonisolated(unsafe) private(set) static var lastTrace: String = ""

    /// Probe the accessibility tree at the given AppKit-space point.
    /// Returns `.text` when the cursor sits on text-like content,
    /// `.nonText(role)` when a role was read but doesn't satisfy text
    /// acceptance, `.failed(reason)` on any AX-layer error.
    static func probe(at appKitPoint: CGPoint) -> TextProbeOutcome {
        var trace: [String] = []
        defer { lastTrace = trace.joined(separator: "\n") }

        // Convert AppKit point (origin bottom-left, primary screen) to
        // Quartz point (origin top-left, primary screen). Inline the
        // primary-screen flip rather than reaching into AXWordReader —
        // the helper there is private. Same convention either way.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        guard let primary else {
            trace.append("FAIL: no primary screen")
            return .failed("no primary screen")
        }
        let axPoint = CGPoint(x: appKitPoint.x, y: primary.frame.maxY - appKitPoint.y)
        trace.append("appKit=(\(Int(appKitPoint.x)),\(Int(appKitPoint.y))) ax=(\(Int(axPoint.x)),\(Int(axPoint.y)))")

        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &hitElement
        )
        guard hitError == .success, let hit = hitElement else {
            trace.append("FAIL: AXUIElementCopyElementAtPosition err=\(hitError.rawValue)")
            return .failed("AXUIElementCopyElementAtPosition err=\(hitError.rawValue)")
        }

        // Walk hit element + up to `parentWalkDepth` parents looking for
        // ANY level that satisfies acceptance. WebKit `AXGroup` containers
        // hide a text leaf one or two levels up; the AppKit Mail viewer
        // wraps its content in `AXScrollArea`. Acceptance via either role
        // match, title match (for AXLink / AXMenuItem), kAXNumberOfCharacters,
        // OR kAXValueAttribute being a non-empty String.
        var current: AXUIElement = hit
        var firstRole: String?
        for depth in 0...parentWalkDepth {
            let role = readRole(current)
            let subrole = readSubrole(current)
            let chars = readNumberOfCharacters(current)
            let value = readStringValue(current, attribute: kAXValueAttribute as String)
            let title = readStringValue(current, attribute: kAXTitleAttribute as String)
            let supportedTextAPIs = readSupportedTextAPIs(current)

            // Compact one-line trace per depth. Truncate value/title to 24
            // chars so a long paragraph doesn't blow up the popup. `params`
            // shows short codes for which text APIs the element advertises:
            // S=StringForRange R=RangeForPosition B=BoundsForRange T=SelectedText
            trace.append(
                "d=\(depth) role=\(role ?? "?") sub=\(subrole ?? "-") chars=\(chars.map(String.init) ?? "-") "
                + "value=\(formatPreview(value)) title=\(formatPreview(title)) params=\(formatTextAPIs(supportedTextAPIs))"
            )

            if depth == 0 {
                firstRole = role
            }

            // Secure text fields: refuse to translate password content
            // even though it's technically text. Privacy > convenience.
            if subrole == "AXSecureTextField" {
                trace.append("  skip d=\(depth): AXSecureTextField subrole")
            } else if let role, nonTextRoles.contains(role) {
                // Hard-excluded role: skip even if it has a String value.
                // The walk continues to a parent — sometimes a button is
                // nested inside a text container we WOULD accept.
                trace.append("  skip d=\(depth): hard-exclude role")
            } else {
                if let role, textRoles.contains(role) {
                    trace.append("  ACCEPT d=\(depth): textRole")
                    return .text
                }
                if let role, titleBearingRoles.contains(role),
                   let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    trace.append("  ACCEPT d=\(depth): titleBearingRole")
                    return .text
                }
                if let chars, chars > 0 {
                    trace.append("  ACCEPT d=\(depth): kAXNumberOfCharacters")
                    return .text
                }
                if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    trace.append("  ACCEPT d=\(depth): kAXValue String")
                    return .text
                }
                // v0.2.4: universal predicate. If the element advertises
                // the macOS text-selection / copy contract (any of the
                // parameterized text attributes, or kAXSelectedText), it
                // is by definition selectable + copyable. This catches
                // Terminal.app / iTerm2 / custom text views that don't
                // populate kAXValue but DO implement the parameterized
                // text API the resolver actually uses.
                if !supportedTextAPIs.isEmpty {
                    trace.append("  ACCEPT d=\(depth): textAPI \(formatTextAPIs(supportedTextAPIs))")
                    return .text
                }
            }

            guard let parent = readParent(current) else {
                trace.append("  stop d=\(depth): no parent")
                break
            }
            current = parent
        }

        trace.append("REJECT: no level accepted (firstRole=\(firstRole ?? "?"))")
        return .nonText(firstRole ?? "unknown")
    }

    // MARK: - AX attribute readers

    private static func readRole(_ element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw)
        guard error == .success else { return nil }
        return raw as? String
    }

    private static func readSubrole(_ element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &raw)
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

    /// Read an attribute as String. Returns nil when the attribute is
    /// missing, the read errors, OR the value is not a String type (e.g.
    /// NSNumber on AXSlider, NSBoolean on AXCheckBox, NSValue on rect-
    /// attrs). The Swift `as? String` cast does the type discrimination —
    /// numeric / boolean values fail it and yield nil automatically, so
    /// the probe never accepts a slider position as if it were text.
    private static func readStringValue(_ element: AXUIElement, attribute: String) -> String? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard error == .success, let raw else { return nil }
        return raw as? String
    }

    private static func formatPreview(_ value: String?) -> String {
        guard let value else { return "-" }
        let collapsed = value.replacingOccurrences(of: "\n", with: "⏎")
        if collapsed.count <= 24 {
            return "\"\(collapsed)\""
        }
        return "\"\(collapsed.prefix(24))…\"(len=\(value.count))"
    }

    /// Returns the subset of macOS AX text APIs that this element claims
    /// to support, by enumerating its attribute and parameterized-
    /// attribute names. Empty when the element exposes none — that's the
    /// AX-layer "this is not selectable text" signal we trust as the
    /// universal predicate.
    ///
    /// One IPC per AX function call (typical 1-2 ms). We make at most
    /// two calls per element here, which the parent walk does up to 5
    /// times. Still well under the ~50 ms tap-response budget.
    private static func readSupportedTextAPIs(_ element: AXUIElement) -> [String] {
        var matched: [String] = []
        var paramNamesRaw: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &paramNamesRaw) == .success,
           let paramNames = paramNamesRaw as? [String] {
            for name in paramNames where textParameterizedAttributes.contains(name) {
                matched.append(name)
            }
        }
        var attrNamesRaw: CFArray?
        if AXUIElementCopyAttributeNames(element, &attrNamesRaw) == .success,
           let attrNames = attrNamesRaw as? [String] {
            for name in attrNames where textApiAttributes.contains(name) {
                matched.append(name)
            }
        }
        return matched
    }

    /// Compact codes for the per-depth trace. `S/R/B/T` instead of full
    /// CFString names keeps the rejection popup readable.
    private static func formatTextAPIs(_ matched: [String]) -> String {
        if matched.isEmpty {
            return "-"
        }
        var codes: [String] = []
        if matched.contains(kAXStringForRangeParameterizedAttribute as String) {
            codes.append("S")
        }
        if matched.contains(kAXRangeForPositionParameterizedAttribute as String) {
            codes.append("R")
        }
        if matched.contains(kAXBoundsForRangeParameterizedAttribute as String) {
            codes.append("B")
        }
        if matched.contains(kAXSelectedTextAttribute as String) {
            codes.append("T")
        }
        return "[\(codes.joined(separator: ""))]"
    }
}
