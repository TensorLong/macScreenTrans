# MacScreenTrans

MacScreenTrans is a macOS status bar translator. Point at a word, trigger the app, and it uses Accessibility plus an OpenAI-compatible streaming API to translate the smallest meaningful phrase that contains that word.

When launched, MacScreenTrans opens its Settings window and keeps running from the `译` item in the macOS menu bar.

## Features

- Visible `译` status bar item with Settings, permission self-check, listening controls, and Quit.
- Three-finger tap listener for translating the word under the cursor.
- Accessibility-only text capture.
- OpenRouter/OpenAI-compatible API settings for endpoint URL, API key, model, target language, and prompt template.
- Floating translation popup with click-outside dismissal.

## Requirements

- macOS 13 or newer.
- Accessibility permission for MacScreenTrans.
- An OpenAI-compatible API key. OpenRouter works with the default endpoint.

## Settings

Open the status bar icon and choose `Settings...`.

- `Endpoint`: API base URL, for example `https://openrouter.ai/api/v1`.
- `API Key`: your provider key.
- `Model`: model id, for example `openai/gpt-4o-mini`.
- `Target`: target language, for example `zh`.
- `Prompt`: editable JSON-only sense-group translation prompt.

## Build

```sh
scripts/test
scripts/package-app release
scripts/package-dmg
```

The packaged app is written to `.build/MacScreenTrans.app`; the release DMG is written to `dist/`.
