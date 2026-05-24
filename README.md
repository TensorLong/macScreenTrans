# MacScreenTrans

MacScreenTrans is a macOS cursor translator. Point at a word, trigger the app, and it uses Accessibility plus an OpenAI-compatible streaming API to translate the smallest meaningful phrase that contains that word.

When launched, MacScreenTrans opens its Settings window, appears as a normal Dock app, and keeps a visible blue `译` menu-bar entry with Settings, permission self-check, listening controls, and Quit.

## Features

- Normal app window plus a visible blue `译` menu-bar entry.
- Guided Chinese Settings page with permission state, API state, test connection, and trackpad settings shortcuts.
- Three-finger tap listener for translating the word under the cursor.
- Accessibility-only text capture.
- OpenRouter/OpenAI-compatible API settings for endpoint URL, API key, model, target language, and prompt template.
- Floating translation popup with copy action and click-outside dismissal.

## Requirements

- macOS 13 or newer.
- Accessibility permission for MacScreenTrans.
- An OpenAI-compatible API key. OpenRouter is the default endpoint.

## Settings

Open MacScreenTrans from `/Applications`; Settings opens automatically. You can also click the blue `译` entry in the menu bar and choose `设置...`.

- `服务地址`: API base URL, default `https://openrouter.ai/api/v1`.
- `API Key`: your provider key. It is edited in a secure field and not shown in status results.
- `模型`: model id, default `openai/gpt-4o-mini`.
- `目标语言`: target language, default `zh`.
- `测试连接`: verifies that the configured model returns a parseable sense group and Chinese translation.
- `权限自检`: checks Accessibility, trackpad listener, endpoint, API key, model, and target language.
- `Prompt 与模型行为`: advanced JSON-only sense-group translation prompt.

## Usage

1. Open MacScreenTrans and grant Accessibility permission when macOS asks.
2. Enter an API key, then click `测试连接`.
3. Put the cursor over selectable text and three-finger tap the trackpad.
4. If macOS opens its own Look Up popup, use `打开触控板设置` and disable the conflicting gesture.

## Build

First-time setup (run once, keeps Accessibility consent across rebuilds):

```sh
scripts/setup-signing-identity
```

This creates a self-signed code signing certificate (`MacScreenTrans Local Signer`) in your login keychain so every packaged bundle gets the same Designated Requirement. Without it, macOS revokes Accessibility consent on every rebuild because ad-hoc signatures are keyed on the executable's cdhash.

Then build as usual:

```sh
scripts/test
scripts/package-app release
scripts/package-dmg
scripts/check-signing            # confirms TCC stability of the bundle
```

The packaged app is written to `.build/MacScreenTrans.app`; the release DMG is written to `dist/`.
