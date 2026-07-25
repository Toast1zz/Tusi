# Tusi

A menubar translator for macOS. Type Chinese and get English; type anything else and get Chinese. The direction is detected automatically, so there is nothing to select.

## Features

- Automatic direction, detected locally by script (works on mixed Chinese/Latin text, no network round-trip)
- Menubar panel, summoned with ⌥Space
- BYOK — any OpenAI-compatible endpoint (DeepSeek, OpenRouter, SiliconFlow, Ollama, …)
- Two API profiles with automatic failover
- Three tone presets (casual / standard / formal)
- Optional auto-copy to clipboard
- Smart quotes on output, leaving code spans and blocks untouched
- Customizable copy shortcut
- Streaming output; adapts to light/dark; Liquid Glass on macOS 26+

## Requirements

- macOS 13+
- An API key for any OpenAI-compatible service

## Install

Download from [Releases](../../releases):

- `Tusi-arm64.zip` — Apple Silicon
- `Tusi-universal.zip` — Apple Silicon + Intel

Unzip and move `Tusi.app` to Applications. On first launch, if Gatekeeper blocks it (the app is not notarized), right-click the app and choose Open.

## Configuration

Open Settings (⌘,) and fill in a profile:

- Base URL, e.g. `https://api.deepseek.com` or `https://openrouter.ai/api/v1`
- Model, e.g. `deepseek-chat`
- API key
- Provider routing (optional) — OpenRouter's `provider.order`, e.g. `novita`

There are two profiles, primary and backup. With failover enabled, a primary request that fails before producing any output is retried on the backup. API keys are stored in the Keychain, not on disk, and each profile has a "test connection" button.

## Shortcuts

| Action | Key |
|---|---|
| Show / hide panel | ⌥Space |
| Translate | ⏎ |
| Newline | ⇧⏎ or ⌘⏎ |
| Copy result | ⇧⌘C (customizable) |
| Settings | ⌘, |
| Back / close | Esc |

## Build

```bash
./build.sh                        # builds build/Tusi.app for the current arch
TUSI_ARCH=universal ./build.sh    # universal binary (arm64 + Intel)
TUSI_VERSION=1.4.3 TUSI_BUILD_NUMBER=12 ./build.sh
```

The default version/build number comes from `VERSION`; CI or release scripts can override
it with `TUSI_VERSION` and `TUSI_BUILD_NUMBER`.

Pure Swift + SwiftUI + AppKit, no third-party dependencies. `build.sh` signs with a local code-signing identity when one is available (so Keychain access survives rebuilds), and falls back to ad-hoc signing otherwise. For public distribution, use a Developer ID identity and notarize the resulting app.

## License

MIT
