# Changelog

All notable changes to Tusi are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.12.2] - 2026-09-03

### Fixed

- **Scrolling either text area could cut the top and bottom rows through the middle of the glyphs.** Both areas are capped at a whole number of lines, and both were already aligned at the two positions the app scrolls them to itself — the top of the text, and the end of it. A trackpad is the case neither covers: it leaves the view wherever the flick stopped, and an offset that is not a multiple of the line step slices the rows at both edges. That is why it looked intermittent — whether it clipped depended entirely on where the scroll happened to stop, not on the text. Both areas now settle onto the line grid when the scroll ends, moving by at most half a line
- **A translation longer than fourteen lines stopped mid-sentence with nothing to say so.** The cap was inherited from a panel that had a system scroller to signal the rest; that scroller was an opaque white gutter against this panel and was removed in 1.12.1, which left the result simply ending. The result's cap is now twenty-four lines — as tall as the panel can be without taking over the screen, and no longer an editorial opinion about how much translation is worth showing — and a result that still overflows fades its last line rather than ending flat. The input keeps its six-line cap: it is a draft whose contents the user already knows, while the translation is the thing they came for

## [1.12.1] - 2026-09-03

### Fixed

- **The panel stopped sizing itself to its own content.** With a slightly longer text the window kept the height it had while the result grew past the bottom edge, taking the tone selector, the language picker and the copy button off the panel with it. Other times it settled too tall or too short, with the slack split evenly above and below the content. Three separate defects, found by tracing the measurements rather than by reading the code:
  - The height reached the window through *three* measurement hops — the result text sized the result viewport, which sized the result section, which sized the content, which sized the window — and every hop was a preference feeding a `@State` that set the next hop's frame. SwiftUI does not promise to redeliver a preference for the layout its own state write caused, and the third hop is where the delivery went missing: `result section 238.0` arrived and the `content` that should have followed it never did, leaving the window sized for the previous result. The middle hop is gone. The result's natural height now reaches the layout in the same pass that measures it, so there is no second delivery left to lose; the history list keeps its explicit viewport, that path never had the loop
  - A height the window failed to reach could never be repaired. The resize compared each new measurement against the last height the panel had *asked* for, so once intent and reality came apart the comparison swallowed precisely the report that would have put them back together. And they did come apart, routinely: two height reports arriving in the same layout cycle leave the second animated resize parked at the first one's starting height. The comparison is against the window's real height now, and a resize that has not landed once the animation is over is snapped
  - The panel could not be shorter than 100pt, but its own smallest content — an empty one-line input plus the bottom bar — measures 86pt. The floor was padding the emptiest state with 14pt of nothing, which read as the bottom bar sitting too high. The floor is 60pt, under anything the panel legitimately wants, and exists only to reject a nonsense measurement
- **Text sat on the wrong line grid, in both halves of the panel.** The panel measured its input with the metrics of a `Text`, but the input is a `TextEditor`, and the two do not lay text out the same way — on this font a `Text` line is 19pt then 22pt per line, an editor line is 18pt then 21pt. The six-line input cap was therefore computed as 129pt when six editor lines are 123pt, and the extra 6pt showed the clipped top of a seventh line above the text. Worse, every scrolled position landed mid-row: the top of the viewport fell 8pt into a line rather than on a boundary. The input is now measured with the layout manager the editor itself uses, so the cap is exactly six editor lines and the arithmetic that keeps the viewport on line boundaries follows from it rather than being arranged
- **The bottom line of a scrolling input or result had nothing under it.** TextKit puts line spacing *between* fragments, so the last line's measurement stops at its glyph box: six lines measure 21+21+21+21+21+18. Sized to that, the bottom line sits flush against the clip edge with no room for a descender or the caret, which reads as the line being shaved — and scrolled to the end, where the content's last pixel is the viewport's last pixel, no frame height can help. Both scrollers now reserve the missing gap as a bottom safe-area inset, which keeps 3pt under the last line and, because the reserved range is exactly what the grid was short, also lands the top edge on a line boundary. Measured against live views: without it, a scrolled input showed a 15pt sliver of a line at the top and a flush line at the bottom; with it, neither
- The result no longer draws an opaque white scroller down its right edge. macOS reserves that gutter for an automatic indicator whenever the system is drawing legacy scrollers, which against this transparent panel is a white bar beside the translation. The input editor and the history list had both already been fixed this way; the result was the last holdout
- Content is anchored to the top of the panel. `NSHostingView` centres a root view shorter than its bounds, which is why a wrong height showed up as symmetric padding, or as the panel quietly crushing its own margins, instead of as something visibly broken

### Added

- **The panel checks its own size, in every build.** Once a resize has settled, the panel asks AppKit what the hosted content actually measures (`fittingSize`) — a question no missing preference can corrupt — and compares it with the window. A window too small for its content is grown on the spot, and the last 48 measurements are written to the unified log with it. The chain is recorded into a bounded in-memory ring at all times: an array append per layout pass, no output at all while the panel behaves, evidence the moment it does not. This deliberately ships everywhere rather than in local builds only — the defect above is timing-dependent, and a diagnostic missing from the build people actually run is missing exactly when it is needed
- A verbose per-hop trace for deep dives, off by default: `defaults write com.tusi.app heightDiagnostics -bool true`. Documented in the README

## [1.12.0] - 2026-09-02

### Added

- A local answer is no longer the end of the line: press ⏎ again and an online service translates the same text, keeping both answers. A small label under the result switches between them, and the clipboard always holds whichever one is on screen
- The result now says where it came from, permanently, in the flow of the panel — which slot answered, and whether it only answered because the primary failed. It is a label, not a control: with two answers in hand, the other one is offered as a swap link at the end of the same row, where the "⏎ 换在线重译" offer already sits. One row, one grammar in every state — a statement on the left, the action on the right — and no second segmented pill sitting a few points above the tone selector pretending to be its sibling
- A local answer that is not in the language that was asked for escalates on its own, without a keystroke: that is not a matter of taste, it is the model failing the job. The suspicious answer is kept and stays marked

### Changed

- **Settings: four routing switches became two questions.** "主用失败时自动切换到备用", "谁快用谁", "完成后提示谁更快" and the local slot's "设为翻译模型" are replaced by one "翻译路线" section asking 从哪开始 (本地模型 / 在线服务) and 两套在线服务 (主用优先 / 同时请求). Each appears only when it is a real choice, and each states what the *selected* option does rather than what its label names
- "同时请求" is shown but unselectable when one of the online slots is a local address, with the reason given: a loopback slot wins on network latency alone, which says nothing about which answer is better. It used to be selectable and silently do nothing
- Under "同时请求" the slot tabs no longer offer "设为主用" — both slots are asked at the same time, so there is no primary to set
- The local slot is an ordinary slot with an ordinary role now. It used to be a standing mode that bypassed the primary, the backup, failover and racing entirely; it is the first stage of a route that can continue upward
- Filling in only the local slot counts as a configured app. It used to leave ⏎ reporting "nothing configured"
- Choosing a local start whose slot is not filled in starts online instead of refusing to translate
- ⏎ on a result that already came from the best tier configured does nothing, rather than restarting the route at the local slot and billing for it
- Failure messages name what was actually tried: "两套在线服务都失败了", "本地和在线都失败了"

### Removed

- **Every floating toast.** "%@ 更快", "主用连接失败，已用备用翻译", "已截断至 %d 字" and "复制失败，请重试" each covered the panel's own content for two seconds and then took the information away with them. The first two were never events — they are properties of the result, and they live on the result now. The truncation notice was already stated beside the editor for as long as it was true. A failed copy is reported by the copy button itself, in the place the confirmation appears
- The bottom bar's standing local-model marker, along with the mode it marked
- `FailureKind.localModelNotConfigured`, which no longer has a way to happen

### Fixed

- Switching "谁快用谁" on while "主用失败时自动切换到备用" was off did nothing at all — the race path read the same resolved chain the fallback switch gated — with both switches showing as on and no indication anywhere. Neither switch exists any more, and the arrangement that produced it cannot be expressed
- An escalation that fails leaves the answer you already had exactly where it was, with a quiet line explaining why the second opinion did not arrive, instead of replacing a good translation with an error box
- Escalating updates the newest history entry instead of filing the same input twice

### Fixed

- Installing a new build no longer re-triggers the Keychain authorization prompt. The stable signing identity added in 1.10.0 was only half the fix, and the note that shipped with it — "the 「始终允许」 authorization persists across rebuilds and reinstalls" — was not true. A login-keychain item is guarded by two mechanisms: the ACL's trusted-application list, which matches a signed app by its designated requirement and does survive a rebuild, and the **partition ID list**, which overrides it. Partition entries are `teamid:<TEAM>` for an identity that carries a Team ID and `cdhash:<hash>` for one that does not — and a self-signed certificate has no Team ID, so every click of 「始终允许」 only pinned that one build. The item had accumulated eleven cdhashes. Local builds now sign with an `Apple Development:` identity, whose Team ID is stable across rebuilds; `./build.sh keychain-unpin` repoints an existing item's list once. Release archives keep the anonymous self-signed identity on purpose, because a Development certificate embeds the developer's name and email in the binary and `codesign -dvvv` on a published zip would expose it

### Migration

Existing preferences carry over on first launch by observed behavior, not by switch position: `raceFastestEnabled` with `fallbackEnabled` off maps to 主用优先, because that combination never actually raced. `useLocalModel` becomes a local start. Users who had switched failover off with a usable backup now get automatic failover — that switch only ever chose between translating and showing an error while a working provider sat idle.

## [1.11.8] - 2026-09-02

### Changed

- Every animation that changes the panel's height — page pushes, settings folds, the language picker, history, the result section — now runs for the same duration on the same curve as the window's own resize, so the window and its content start, move and stop together instead of on separate clocks
- The settings page's collapsible "高级选项"/"附加要求" sections now animate open and closed as one motion. Previously the chevron turned over 0.18s, the fields appeared instantly, and the window resized over 0.22s — three phases for one click
- Opening the language picker expands the row into place rather than sliding it up from below the panel edge, matching how every other disclosure in the app behaves
- The result area now crossfades between the waiting skeleton, a finished translation, and an error, instead of cutting between them while the box around them resizes
- The panel's summon fade is faster (0.14s, down from AppKit's default 0.25s) and uses the app's own curve
- Copy confirmation swaps its glyph as a symbol replacement instead of fading two separate icons past each other
- Controls no longer pop or grow: the copy button appears by fading like its neighbours rather than scaling up, stops growing under the cursor, and the Keychain confirmation checkmark no longer scales 30% in 120ms

### Fixed

- History expand/collapse resized the window instantly while its content animated over 0.26s; the window now follows on the same timeline
- "Reduce Motion" now takes effect the moment it is switched on, including stopping the waiting skeleton's pulse, instead of applying whenever a view next happened to redraw

### Removed

- Removed the timer-gated special cases that decided whether a height change should animate, along with the compensation constant they needed

## [1.11.7] - 2026-09-02

### Added

- Added per-profile output-protocol controls and capability-aware connection tests for strict JSON schema, forced tool-call, JSON-object, and plain-text compatible endpoints

### Changed

- Remote translation can use a previously verified structured-output protocol and falls back to plain text once when an endpoint rejects structured formatting; local loopback models remain plain-text-first
- Translation completion sounds now follow the macOS system output volume without an additional in-app volume level
- History now expands from a fixed top anchor with a restrained height reveal and crossfade instead of moving the result and history surfaces through the panel

### Removed

- Removed the sound-volume slider and the user-facing diagnostic-report copy actions

### Fixed

- Structured responses publish only the validated translation field, rejecting refusals, malformed envelopes, extra fields, multiple tool calls, and leaked assistant commentary
- Removed the opaque macOS 27 scrollbar gutter from long history lists while preserving scrolling
- Stopped SwiftUI history-height interpolation from being animated a second time by AppKit, eliminating expand/collapse jitter and the final resize hop

## [1.11.6] - 2026-09-01

### Added

- Unsent source text is restored after relaunch and flushed before normal app termination, so closing the panel or app no longer loses an in-progress draft
- Race decisions now leave privacy-safe unified-log receipts with the selected or rejected slot and host, making the actual remote winner diagnosable after a bad result

### Changed

- Race mode no longer lets a fast wrong-language answer cancel a provider that may still return the requested language. Suspicious candidates remain unpublished while the other provider finishes; the first warned result is preserved only when neither leg produces a target-language translation

### Fixed

- Kept long input drafts scrollable while hiding the opaque system scroll-indicator gutter that could appear against the clear editor

## [1.11.5] - 2026-08-29

### Added

- Added a cautious wrong-language warning for model replies that clearly miss the requested target; suspicious output remains visible but is no longer auto-copied or announced as a clean success
- Added de-identified diagnostics, failure-specific recovery actions, a local-model status marker, remaining-input feedback, sound-volume control, and confirmation before binding bare letter or number shortcuts

### Changed

- Replaced the local model's standalone translation switch with the same role-action pattern used by “Make primary”: “Make translation model” when inactive, a clear current-role state when active, and an explicit return to primary / backup routing
- Clarified that OpenRouter provider order is a preference rather than a restriction, and updated stale project guidance to match atomic result presentation and the current three-profile model

### Fixed

- Improved Keychain errors and recovery, automatic scroll indicators, English-width measurement, localization coverage, and several settings and error-state accessibility details

## [1.11.4] - 2026-08-28

### Fixed

- Completed the audit repair pass for translation recovery, race-mode empty responses, bounded streaming output, SSE protocol validation, and safe redirect handling that never forwards API keys or source text to another host
- Added persistent input-truncation feedback, honest history truncation markers, native Toggle accessibility, stable settings scrolling on short screens, and stronger selected-state semantics for language, tone, and profile controls
- Hardened Keychain and connection-test error reporting, clipboard failure handling, IPv6 loopback normalization, and English localization coverage

## [1.11.3] - 2026-08-28

### Fixed

- Fixed a 1.11.2 bottom-bar layout regression where the new translation button remained visible after a result was available, crowding the copy action at the minimum panel width and allowing controls to wrap vertically. The translation button now appears only before a result exists, and direction/copy labels remain single-line under layout pressure

## [1.11.2] - 2026-08-27

### Fixed

- Translation retry now recognizes real transport failures (timeouts, lost connections and DNS/connectivity errors) and the app's own stream watchdog timeout, instead of only HTTP 5xx and truncated streams. The existing no-splice rule remains: once a provider has produced content, Tusi neither retries nor switches providers
- Race mode no longer lets a provider that returns an empty completion cancel the other provider. It now waits for the first usable complete translation; a concrete provider failure still wins over a meaningless empty-response error when both legs finish unsuccessfully
- History loaded from older or manually edited files is re-bounded to 50 records and 4,000 characters per field. Archived input/output that was shortened now carries an explicit marker, appears with a compact scissors indicator in history, and stays visibly marked as incomplete after restoration
- The bottom-bar “⏎ 翻译” affordance is now a real, keyboard-accessible button while keeping the existing Return shortcut
- Copy confirmation is now shown only when the pasteboard write succeeds; a failed write surfaces a short retry notice instead of a false “Copied” state

### Changed

- API Key privacy copy now accurately states that it is kept in the local Keychain and sent only to the API service configured by the user
- npm metadata now matches the app release: version 1.11.2, MIT license and `swift test` as the test command

## [1.11.1] - 2026-08-26

### Changed

- Replaced every spring-based UI animation (`.snappy`, used for folds, page pushes, toggles, panel resizing, toasts) with a single deceleration-curve motion system — a tool panel's chrome is a state switch, not a direct-manipulation gesture, and shouldn't overshoot. Most call sites had actually been bypassing the app's Reduce-Motion/TUSI_SLOWMO handling entirely (a raw `.snappy(duration:)` instead of the wrapped helper); the new system routes everything through one entry point so neither can be silently skipped again, enforced by a CI check
- The settings page's three profile tabs, all `Color.primary.opacity(…)` fills, and the corner-radius scale were each collapsed from several near-duplicate values (picked at different times, indistinguishable to the eye) down to a small set of named tokens
- The inline language-picker pills now react to hover, matching every other control in that row
- Toasts (fallback notice, input-truncation notice, race-winner notice) now all appear from the same spot at the top of the panel instead of two different overlays, and slide in rather than scale in
- Page transitions between the translator, settings, and shortcuts pages now use a parallax retreat (the outgoing page travels half the distance while fading) instead of both pages travelling the full panel width past each other

### Fixed

- The settings page's collapsible "高级选项"/"附加要求" sections no longer animate their own reveal — the field pops in immediately and the panel's own window resize (now using a standard, evenly-decelerating ease-out curve instead of a hand-picked one that front-loaded most of the motion into the first fifth of the duration) is the only visible motion, which is what actually reads as a clean fold instead of a multi-phase one
- The race-toast sub-toggle's label now lines up with every other settings row instead of sitting indented

## [1.11.0] - 2026-08-25

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

[1.12.2]: https://github.com/Toast1zz/Tusi/releases/tag/v1.12.2
[1.12.1]: https://github.com/Toast1zz/Tusi/releases/tag/v1.12.1
[1.12.0]: https://github.com/Toast1zz/Tusi/releases/tag/v1.12.0
[1.11.7]: https://github.com/Toast1zz/Tusi/releases/tag/v1.11.7
[1.11.6]: https://github.com/Toast1zz/Tusi/releases/tag/v1.11.6
[1.11.5]: https://github.com/Toast1zz/Tusi/releases/tag/v1.11.5
[1.11.4]: https://github.com/Toast1zz/Tusi/releases/tag/v1.11.4
[1.11.3]: https://github.com/Toast1zz/Tusi/releases/tag/v1.11.3
[1.11.2]: https://github.com/Toast1zz/Tusi/releases/tag/v1.11.2
[1.11.1]: https://github.com/Toast1zz/Tusi/releases/tag/v1.11.1
[1.11.0]: https://github.com/Toast1zz/Tusi/releases/tag/v1.11.0
[1.10.0]: https://github.com/Toast1zz/Tusi/releases/tag/v1.10.0
[1.9.0]: https://github.com/Toast1zz/Tusi/releases/tag/v1.9.0
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
