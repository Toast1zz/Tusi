# Changelog

All notable changes to Tusi are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.1] - 2026-07-31

### Removed

- Conversation context turns setting: translations are single-turn requests again, no history is sent to the model

## [1.6.0] - 2026-07-31

### Added

- Multi-language mode: explicit target-language selection (settings toggle + picker); the auto-detected source is left alone, and choosing a target equal to the source re-picks the direction
- Conversation context setting: send the last 0–6 turns of the conversation to the model as context
- Hotkey rebinding now rolls back to the previously registered combo when the new one is rejected (e.g. owned by another app), so a failed rebind never silently kills the working shortcut
- Warning when a shortcut has no modifier and binds a letter/digit, since that key becomes untypeable while the app is active

### Changed

- Minimum system version raised to macOS 14 (`.snappy` animations used throughout the UI are macOS 14+ APIs); README and packaged `Info.plist` updated to match
- Loopback detection now covers the whole `127.0.0.0/8` range, not just `127.0.0.1`
- Update checks: only a genuinely completed check counts against the throttling window — failed or superseded checks leave the last-check timestamp untouched so the next launch retries
- Version comparison is now prerelease-aware: `1.6.0` beats `1.6.0-beta.1`, and prerelease segments compare numerically (`beta.2` > `beta.1`)
- Debug preview scenarios (`TUSI_PREVIEW`) extracted into `PreviewSupport.swift`, keeping production launch logic out of `AppDelegate`

### Fixed

- Tests could not reset the preview-scratch history file (`historyURL(preview:)` was private)

## [1.6.0-beta.1] - 2026-07-31

### Added

- Manual direction flip with override persistence
- Preview-mode history isolation: preview/screenshot runs use a scratch history directory (`com.tusi.preview`) so they never read or clobber real history
- Build script supports `TUSI_ARCH=arm64` / `universal` and per-arch show-bin-path handling

### Changed

- Translate contract hardening: conversation context now always orders newest-first (`user, assistant, user, assistant, …`) regardless of when inserts land

## [1.5.1] - 2026-07-25

### Fixed

- Keychain save race: rapid edits to both profile slots within the debounce window could drop the first slot's key; pending keys now merge instead of being replaced

## [1.5.0] - 2026-07-25

### Added

- Two API profiles (primary + backup) with automatic failover when a primary request fails before producing any output
- OpenRouter `provider.order` routing hint (sent only to OpenRouter hosts)
- Keychain migration from legacy single-key storage, with retry-safe writes and surfaced error states

### Changed

- API keys consolidated into a single Keychain record; writes are `AfterFirstUnlock`-accessible and retried on later edits or shutdown

## [1.4.3] - 2026-07-25

First tagged release.

### Added

- Menubar translator: type Chinese and get English, type anything else and get Chinese
- Automatic direction detection, done locally by script (no network round-trip), works on mixed Chinese/Latin text
- ⌥Space panel with streaming output, three tone presets (casual / standard / formal), optional auto-copy, smart quotes that leave code spans untouched
- BYOK: any OpenAI-compatible endpoint (DeepSeek, OpenRouter, SiliconFlow, Ollama, …)
- Customizable shortcuts and English localization
- In-app update check against GitHub Releases (prompts, never auto-installs)

[1.6.1]: https://github.com/neko1chau/Tusi/releases/tag/v1.6.1
[1.6.0]: https://github.com/neko1chau/Tusi/releases/tag/1.6.0
[1.6.0-beta.1]: https://github.com/neko1chau/Tusi/releases/tag/1.6.0-beta.1
[1.5.1]: https://github.com/neko1chau/Tusi/releases/tag/1.5.1
[1.5.0]: https://github.com/neko1chau/Tusi/releases/tag/1.5.0
[1.4.3]: https://github.com/neko1chau/Tusi/releases/tag/1.4.3
