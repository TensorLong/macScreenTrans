# MacScreenTrans Spec

## Scope

MacScreenTrans is a macOS status-bar app for context-aware word translation. The user hovers a word, performs a three-finger trackpad tap, and the app shows a floating streaming LLM response near the cursor.

## Product Behavior

- Trigger: native three-finger trackpad tap, implemented through `MultitouchSupport.framework` via `Sources/CMultitouchSupport`.
- Manual trigger: the status-bar menu includes `Translate Under Cursor`, which runs the same handler for verification and accessibility fallback.
- Automation trigger: the app also listens for the local distributed notification `com.longmac.MacScreenTrans.translateUnderCursor`, used by desktop E2E tests without moving the cursor away from the target word.
- Cursor capture: uses `NSEvent.mouseLocation` at trigger time.
- Text capture: uses Accessibility API only.
  - `AXUIElementCopyElementAtPosition`
  - `AXRangeForPosition`
  - `AXValue` or `AXStringForRange`
- Unsupported positions show `当前位置不支持取词`.
- LLM call: OpenAI-compatible `/v1/chat/completions` with `stream: true`.
- Output: token deltas render incrementally in a floating panel near the cursor.
- Close: `ESC` closes the floating panel.

## Configuration

Stored in `UserDefaults` for v1:

- Endpoint
- API key
- Model
- Target language
- Prompt template

Default prompt matches the reference sense-group contract from `/Users/longmac/sideProjects/screenTrans`: JSON-only output with `source_chunk` and `target_chunk`.

## Permissions

The app checks Accessibility trust at launch. If missing, it opens the settings window and asks macOS to prompt for Accessibility authorization.

The settings window includes a self-check for:

- Accessibility trust
- Trackpad monitor status
- Endpoint validity
- API key presence
- Model presence
- Target language

Trackpad data is read directly through the private system `MultitouchSupport.framework`; no BetterTouchTool, Hammerspoon, event-tap gesture utility, OCR, or screen recording fallback is used.

## Non-Goals

- No OCR fallback.
- No local model inference.
- No history, favorites, sync, or App Store packaging.
- No attempt to translate entire sentences when AX cannot provide a pointed word.

## Build And Test

Install current Command Line Tools if the Swift Testing framework is unavailable:

```sh
softwareupdate --install "Command Line Tools for Xcode 26.5-26.5" --verbose
```

Build:

```sh
swift build
```

Create a local app bundle for desktop testing:

```sh
scripts/package-app
open .build/MacScreenTrans.app
```

Run tests:

```sh
scripts/test
```

`scripts/test` passes the CLT Swift Testing framework search paths explicitly. On this machine, plain `swift test` can find the compiler but not reliably load the CLT Swift Testing runtime.

Run the optional OpenRouter streaming smoke test by providing environment variables:

```sh
MACSCREENTRANS_OPENROUTER_API_KEY=... \
MACSCREENTRANS_OPENROUTER_ENDPOINT=https://openrouter.ai/api/v1 \
MACSCREENTRANS_OPENROUTER_MODEL=openai/gpt-4o-mini \
scripts/test
```

The OpenRouter test is skipped when no API key is present.
