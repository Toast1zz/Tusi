# Changelog

All notable changes to Tusi are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.10.0] - 2026-08-25

### Added

- Race mode ("谁快用谁" in Settings): when both primary and backup are usable remote APIs, fires a request to both concurrently and commits whichever answers first, cancelling the other. Off by default (it doubles outbound requests per translation while both slots are usable) and never engages when either slot is a local/loopback endpoint, which would trivially win every race regardless of answer quality. A companion "完成后提示谁更快" switch (on by default whenever racing is on, independently toggleable) flashes a one-time toast at the top of the panel naming the winner
- A dedicated third profile slot for a local model, fully separate from the primary/backup pair — it never races, never fails over, never enters the automatic chain. A single switch on its own Settings tab, "翻译时使用这个模型", is the entire manual-only contract: on, ⏎ translates only through that slot; off, nothing changes
- The multi-language target picker moved out of Settings and into the panel itself: tapping the direction chip expands an inline row of language pills (plus a swap action in auto mode) right above the bottom bar, so switching targets no longer requires leaving the translator view
- A stream that goes idle mid-response (a token or two, then silence) is now caught by a 45-second idle watchdog, instead of only guarding against nothing arriving at all — the previous behavior left a stalled stream running until URLSession's 300-second resource timeout
- A stream ending without the `[DONE]` sentinel is no longer automatically treated as truncated: a non-null `finish_reason` on the last chunk is accepted as completion too, for gateways that close the connection cleanly instead of sending the sentinel
- Pasting text past the 32,000-character input cap now shows a toast ("已截断至 32000 字") instead of truncating silently

### Changed

- Settings' three profile tabs (主用/备用/本地模型) now share their row equally and show a short provider name ("deepseek", "commandcode") instead of the full host, which no longer fits once three tabs split one row
- "附加要求（可选）" is now collapsible, matching "高级选项" — collapsed by default unless it already holds a value
- Every row in the lower half of Settings (toggles, sound row, race controls) now shares one consistent vertical rhythm instead of three separately-spaced blocks
- History records are capped at 4,000 characters per field when archived, bounding the worst-case synchronous write; the current panel's own input/output are unaffected
- The panel now respects System Settings ▸ Accessibility ▸ Reduce Motion, and its height is clamped to the current screen so a long result on a small display can't push its bottom edge off-screen
- `DirectionChip` is a real button now, reachable and activatable by Tab/VoiceOver instead of only by mouse

### Fixed

- The API Key field's focus highlight, which never actually appeared due to a misdirected `.focused()` modifier
- The Keychain "saved" confirmation, which was fully wired up but never surfaced anywhere in the UI
- The translated result's left edge, which sat 5pt to the left of the source text's due to a `TextEditor` inset the result view wasn't accounting for

## [1.9.4] - 2026-08-20

### Changed

- Multi-language mode now offers only the four core targets — 中文 / English / 日本語 / 한국어 — instead of the full 17-language grid. That keeps the picker to a single row and matches how these modes are actually used; other languages can still be detected as the source of the input, they just aren't offered as a translation target. The direction auto-correct only falls back to targets still in the picker, so older history entries (e.g. a French choice from a previous build) can no longer surface an unselectable target

## [1.9.3] - 2026-08-20

### Fixed

- Multi-language mode: selecting 中文 (or any language equal to the empty-input source placeholder) no longer gets auto-flipped away. With an empty input the detected source is just a placeholder (usually Chinese), so it no longer vetoes the user's explicit target choice — the target now sticks whether you pick 中文, 日本語 or anything else before typing. The "translate X into X" auto-correct still applies once there is real input

## [1.9.2] - 2026-08-20

### Fixed

- Multi-language mode: choosing a target language no longer fails when the input is empty. The target-language grid in Settings is visible before any text is typed, but selecting one (e.g. 日本語) was silently ignored until the input contained text — the selection now registers immediately, so switching to Japanese works from a fresh panel

## [1.10.0] - 2026-08-20

### Added

- Local (loopback) endpoints no longer require an API key. Ollama, LM Studio, and llama.cpp-server are OpenAI-compatible and authenticate differently or not at all, so a `localhost` / `127.0.0.0/8` / `::1` base URL now works with an empty key — point Tusi at your local server (e.g. `http://localhost:11434/v1` or `http://localhost:8080/v1`) and it just works, no fake key required
- Local servers no longer receive a `Bearer` token they never asked for — only remote endpoints get an `Authorization` header
- Settings hides the API Key field for local endpoints and shows "本地服务无需 API Key" instead, so nobody is pushed to type a placeholder key

### Changed

- A local (loopback) profile is usable with just an address + model; remote profiles still require an API key. Stale keys from an earlier remote configuration are no longer backfilled into a slot now used for local

## [1.9.1] - 2026-08-20

### Changed

- Local and online translations now share the same presentation rhythm: streamed chunks remain behind the waiting placeholder and the complete result appears at once when translation finishes
- The copy action appears only after a usable result is available; the in-progress result area consistently shows the waiting placeholder

### Fixed

- Local models no longer receive source text wrapped in `<translate>` markers, preventing smaller models from echoing those tags; boundary cleanup also removes wrappers returned by cached templates or gateways without altering literal tags inside a translation
- Stopping a translation publishes any buffered partial result once and marks it incomplete, while a failed stream discards partial content and preserves the existing no-splice failover guard

## [1.9.0] - 2026-08-19

### Added

- Transient network failures (TCP reset, 5xx, timeout) are now retried once on the same provider before failing over — a one-off hiccup no longer needs a backup profile to recover
- First-token timeout for translation streams: a server that accepts the request but never produces data (hung gateway, model queueing) now fails with "服务器长时间无响应，请稍后重试" after 30 seconds instead of leaving the user staring at an endless "working" state (URLSession's request timeout only covers response headers; the old behavior could wait the full 5-minute resource timeout)
- Results longer than 64,000 characters are now truncated to the cap and flagged "结果过长，已截断，仅保留开头部分" — a rambling model run never grows the panel or the history file without bound, and a capped result skips the auto-copy and the success sound (a run that had to be cut is not a clean completion)
- Settings shows a brief "API Key 已保存到钥匙串" confirmation after a key lands in the Keychain, so the debounced save no longer feels silent
- `os.Logger` diagnostics across the translation, update-check, keychain, app-launch and sound paths; failures (stream errors, keychain writes, update checks, history writes) now leave a trail in the unified log (`log stream --predicate 'subsystem == "com.tusi.app"'`)
- Update-checker network tests: failed / available / up-to-date states are now covered with a mock session

### Changed

- `build.sh` applies `-strict-concurrency=complete -warnings-as-errors` to **every** arch mode (native, arm64, universal) — the release zips are gated exactly like the debug loop, not just the `native` path
- History rows show the full record text in a hover tooltip, so a long entry is readable without opening it

### Fixed

- Swift 6 concurrency readiness: the test-only `sessionOverride` seam is `nonisolated(unsafe)` with documentation, the Carbon hotkey callback captures a `@Sendable` closure instead of the manager, and `PanelController` uses a main-actor-isolated `deinit` so its observers tear down safely. The project now builds clean under `-strict-concurrency=complete` (zero warnings)

## [1.8.0] - 2026-08-18

### Added

- A completion sound when a translation result fully arrives (the `success` cue from the `scifi` pack of [uisfx](https://uisfx.com), CC0 audio). A "翻译成功音效" switch in Settings persists the preference (on by default) with a "试听" button that previews the cue even when the switch is off; no other interactions make sound

### Fixed

- The pin button in the bottom bar visually sat higher than its neighbors because the `pin` SF Symbol's glyph is 1pt taller than the circular `clock`/`gearshape` glyphs; it is now nudged down 0.5pt to align optically
- `Tusi Dev Signing` lost its trust setting (self-signed cert), which made every `./build.sh install` prompt for keychain authorization; the certificate is trusted again so builds sign silently

## [1.7.4] - 2026-08-17

### Fixed

- Changing the multi-language target during an active translation now cancels the in-flight request and restarts the current input with the newly selected language; toggling multi-language mode refreshes the direction and request as well

## [1.7.3] - 2026-08-15

### Added

- API keys are re-read from the Keychain once the system unlocks, when a login-item launch before the first unlock of a boot read an empty Keychain — the keys appear without a restart
- `applicationSupportsSecureRestorableState` is implemented

### Changed

- Pasting more than 32,000 characters into the input is truncated at the boundary instead of being sent whole and stored in history records
- Line-height caps for the input/result areas are derived from font metrics instead of hardcoded constants, so larger system fonts no longer clip whole lines
- SSE parsing no longer runs on the main thread; a fast or large stream can't jank the panel
- The dev signing identity lives in the login keychain (unlocked automatically at login), so builds never ask for a keychain password; `build.sh` verifies the signature after signing. The dedicated-keychain flow remains as an override
- Release archives are packed without filesystem metadata (`ditto --norsrc`), so the zips extract to a cleanly verifiable signature with any tool
- Update-check and release links follow the repository move to `Toast1zz/Tusi`

## [1.7.2] - 2026-08-14

### Added

- Shortcuts can now be unbound entirely: each shortcut row in Settings → Shortcuts gains a clear (✕) button, and an unbound shortcut displays "Unassigned" instead of a key combo. Re-record or restore the default to bind it again
- The global summon hotkey can be unbound too — with no hotkey registered the panel still opens from the menu-bar icon, and the "hotkey failed" warning no longer applies
- Unbound shortcuts are skipped by conflict detection, and the copy button hides its key hint when the copy shortcut is unbound

## [1.7.1] - 2026-08-13

### Added

- `./build.sh release` builds both arch slices (arm64 + universal) and packs clean `dist/Tusi-*.zip` archives with `ditto` (no `__MACOSX` junk)

### Changed

- Stopping a translation now applies the smart-quote pass to the partial output and marks the result "Stopped — result is incomplete", so a half-open quote pair is fixed up and the incomplete result is clearly flagged
- The menu's update item no longer shows a stale update while a check is running; a known update now survives a failed re-check instead of being cleared
- Streaming requests send an explicit `Accept: text/event-stream` header
- Builds are signed with a dedicated self-signed identity (Tusi Dev Signing) kept in its own keychain, so the Keychain "Always Allow" authorization persists across rebuilds and reinstalls instead of re-prompting on every install

### Fixed

- A base URL containing a query string is rejected as invalid instead of producing a malformed request
- `build.sh release` previously ignored the `release` positional argument (silently building the native arch); the argument is now honored

## [1.7.0] - 2026-08-11

### Changed

- Streaming is now coalesced: SSE chunks accumulate and are published at most ~30×/s instead of once per network packet, so a fast stream no longer re-lays-out the result view at network speed (the panel still animates smoothly, just at a sane frame rate)
- The result view auto-scrolls during streaming only while the user is already at the bottom — reading an earlier part of a long translation no longer yanks the viewport back to the tail
- The panel's height follows the streamed text directly instead of stacking a new 0.25s animation per line; the eased resize is reserved for discrete layout jumps
- Input height measurement is memoized by (text, width), so streaming chunks no longer re-measure the unchanged input hundreds of times

### Fixed

- The smart-quote pass now pairs backtick delimiters: a stray unpaired backtick in the model's output no longer disables quote conversion for the rest of the text
- Two error messages ("primary connection failed" and "no usable API service configured") rendered in Chinese on English systems — their localization keys are now present
- A connection closed cleanly by the server before the `[DONE]` sentinel is treated as truncated instead of a complete translation, and partial output is discarded per the existing mid-stream failure contract
- The settings "test connection" task now explicitly runs on the main actor instead of inheriting ambiguous isolation from the view context
- Update-check failure paths no longer leave a stale task reference behind

## [1.6.2] - 2026-07-31

### Changed

- Translation direction / target language can no longer be switched while a translation is in flight — the running request captured its target at launch, and flipping mid-stream left the direction chip disagreeing with the result. Stop first, then switch
- Scheme-less loopback base URLs (`localhost:11434/v1`) now default to HTTP instead of a guaranteed-to-fail HTTPS; remote hosts keep the HTTPS default

### Fixed

- The Fn modifier could get baked into a recorded shortcut (recorded while Fn was held), making the shortcut never match afterwards; Fn is now stripped like Caps Lock and the keypad flags
- History file writes could complete out of order (an older snapshot overwriting a newer one, or a cleared history resurrecting itself on next launch); saves are now synchronous and strictly ordered, and the final entry always lands before app exit
- One corrupt history record silently discarded the entire history; records now decode individually and the good ones survive
- The error message claimed "both primary and backup failed" when the backup was never tried (a mid-stream failure deliberately skips failover); the message now distinguishes the two cases
- Version comparison treated `+build` metadata as a version component (`1.6.0+build.5` outranked `1.6.0`); build metadata is now ignored per semver
- Error responses were read line-by-line, so one oversized line (e.g. a multi-MB HTML page with no newlines) was buffered in full; the error body is now capped at 8 KiB of bytes
- The language detector could report source `.chinese` with the label `文` when the recognizer had no answer; the fallback label is now consistent
- The "nothing configured" message only mentioned the API key even when the model or base URL was what was missing
- TUSI_PREVIEW screenshot runs could fire a real update check and write the real throttle timestamp; preview runs now skip update checks entirely
- Settings profile-slot index gained an out-of-range guard (degrade to slot 0 instead of crashing on a broken invariant)

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

[1.9.0]: https://github.com/Toast1zz/Tusi/releases/tag/v1.9.0
[1.10.0]: https://github.com/Toast1zz/Tusi/releases/tag/v1.10.0
[1.7.3]: https://github.com/Toast1zz/Tusi/releases/tag/v1.7.3
[1.7.2]: https://github.com/Toast1zz/Tusi/releases/tag/v1.7.2
[1.7.1]: https://github.com/Toast1zz/Tusi/releases/tag/v1.7.1
[1.6.2]: https://github.com/Toast1zz/Tusi/releases/tag/v1.6.2
[1.7.0]: https://github.com/Toast1zz/Tusi/releases/tag/v1.7.0
[1.6.1]: https://github.com/Toast1zz/Tusi/releases/tag/v1.6.1
[1.6.0]: https://github.com/Toast1zz/Tusi/releases/tag/1.6.0
[1.6.0-beta.1]: https://github.com/Toast1zz/Tusi/releases/tag/1.6.0-beta.1
[1.5.1]: https://github.com/Toast1zz/Tusi/releases/tag/1.5.1
[1.5.0]: https://github.com/Toast1zz/Tusi/releases/tag/1.5.0
[1.4.3]: https://github.com/Toast1zz/Tusi/releases/tag/1.4.3
