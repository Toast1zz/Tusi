# Tusi

A menubar translator for macOS. Type Chinese and get English; type another
language and get Chinese. Tusi detects the direction automatically, with explicit
target languages available when needed.

## Features

- Automatic direction detection on your Mac, including mixed Chinese/Latin text
- Explicit targets when you want them: English, Chinese, Japanese, Korean
- Menubar panel, summoned with ⌥Space
- Bring your own key for an OpenAI-compatible service (DeepSeek, OpenRouter,
  SiliconFlow, and others), or use a local server without a key
- Three slots: primary and backup online services, plus a local-model slot
- Start local and press ⏎ again for an online second opinion — both answers are kept, and
  the clipboard follows whichever one you are looking at
- Hold Return for 1.5 seconds to translate a completed result again; an optional switch in
  Settings → Translation controls both the gesture and its progress hint
- Two online services, used either primary-first or asked at the same time
- Casual, Standard, and Formal tone presets, plus optional Auto tone using Jev; Auto
  shows its choice with the result and falls back to Standard when it cannot decide
- A standing instruction carried by every request — a glossary entry, a house style, a name
  to leave untranslated
- Optional auto-copy to clipboard, an optional completion sound, and a local history of the
  last 50 translations
- Smart quotes on output, leaving code spans and blocks untouched
- Talks to endpoints that only pretend to be OpenAI-compatible: it prefers structured output,
  notices the first time a server cannot do it, and retries that request as plain text
- Optional launch at login, and an optional check for new releases
- Every shortcut is rebindable except ⌘, for Settings
- The result appears complete, in one step — no token-by-token flicker, and local and remote
  models behave identically. Adapts to light/dark; Liquid Glass on macOS 26+

## Requirements

- macOS 14+
- An API key for any OpenAI-compatible service — or nothing but a local model
  (Ollama, LM Studio, llama.cpp-server), which needs none
- A Jev API key to use Jev-driven Auto tone; without one, Auto uses Standard

## Install

Download from [Releases](../../releases):

- `Tusi-arm64.zip` — Apple Silicon
- `Tusi-universal.zip` — Apple Silicon + Intel

Unzip and move `Tusi.app` to Applications. On first launch, if Gatekeeper
blocks it (the app is not notarized), right-click the app and choose Open.

## Configuration

Open Settings (⌘,) → Services. Choose a primary or backup online profile, the
local-model slot, or the separate Jev tab. A selected translation tab shows its
provider or host; unselected tabs show only their names. For an online profile, enter:

- Base URL, e.g. `https://api.deepseek.com` or `https://openrouter.ai/api/v1`
- Model, e.g. `deepseek-flash`
- API key
- Provider preference order (optional, under Advanced) — OpenRouter's
  `provider.order`, e.g. `novita`. It is a preference, not a restriction:
  OpenRouter may still fall back to a provider you did not list.

The local slot has an enable switch. It can discover GGUF files and switch models
through an existing `~/Library/LaunchAgents/com.tusi.llamaserver.plist` service
bound to `127.0.0.1:8080`. Disabling the managed model unloads it without
deleting its files or selection. Choosing another model while disabled saves that
choice without starting the service; switching while enabled unloads the previous
process first. The runtime and model files must already be installed. Other local
servers can be configured manually under Advanced.

Settings → Translation → Route controls how the three translation slots
(primary, backup, and local) are used:

- **Start with** — the local model, or an online service. Starting local does not
  mean local only: the local answer arrives first, and one more ⏎ asks an online
  service for its own version. Both are kept, and a small label under the result
  switches between them.
- **Two online services** — Primary first (the backup takes over only when the
  primary fails) or Ask both (both are asked at once; the first usable answer wins).
  Both services may charge in the latter mode. It is offered only when both slots are
  remote: a loopback server would win on network latency alone.

Each question appears only when it is a real choice. With a backup configured, a
primary request that fails before producing any output can fail over to it. API
keys are stored in the macOS Keychain rather than profile preferences, and each
service has a connection test.

The Jev tab holds a separate API key and Test Connection button. Choosing Auto tone sends
the source text to Jev once when translation starts, then uses the chosen Casual,
Standard, or Formal preset for that request, including retries and higher-tier results.
If the key is missing, Jev is unavailable, or the decision is unclear, translation
continues with Standard. The Jev connection test sends a fixed sample sentence, not your
draft. Translation-service connection tests use the same protocol negotiation as real
translations and send at most two short requests. Automatic update checks run at startup
and every six hours while enabled.

History retains both local and online versions, including the host and model that answered.
Each archived text field is limited to 4,000 characters and 32 KB; truncated versions stay
marked. Right-click a record to delete it. Clear History returns to the translator and
shows an Undo row above its bottom bar. That undo lasts until a new translation starts,
Settings opens, or history is opened and closed again. Deleting one record keeps history
open with Undo beside Clear History until you leave history. History and draft saving can
be disabled independently in Settings. Turning off saving deletes the corresponding saved
data; clearing the input draft does not delete history. Text is stored locally with
owner-only file permissions, without encryption.

Two controls are available when you need them:

- **Additional instructions (optional)** (Settings → Translation) — one instruction
  added to every translation request, whichever profile answers it. Use it for a
  glossary rule, a house style, or a name that must remain untranslated. The field
  starts collapsed when empty.
- **Output protocol** (Advanced, per profile) — Automatic (recommended) asks for
  structured output and, if a server does not support it, retries as plain text.
  Choose Plain-text compatibility for an endpoint that advertises structured output but
  does not honour it. Only the request format changes; the translation stays the same.

If a freshly installed build asks you to authorize the API keys again, run
`./build.sh keychain-unpin` once. macOS guards a Keychain item with a partition list whose
entries are `teamid:` for an app signed by an identity carrying a Team ID and `cdhash:` for
one that is not — and a cdhash changes with every build, so a self-signed app looks like a
new application each time no matter how stably it is signed. Local builds therefore prefer
an `Apple Development:` identity if one is present; the command above repoints an existing
item at that Team ID. Release archives stay on the anonymous self-signed identity,
since a Development certificate carries the developer's name and email.

Before macOS completes its first unlock after boot, the Keychain is not yet
accessible. A login-item launch that early may briefly see no API key; Tusi
recovers automatically once the system is unlocked.

## Shortcuts

| Action | Key |
|---|---|
| Show / hide panel | ⌥Space |
| Translate | ⏎ |
| Retranslate online (after a local answer) | ⏎ again |
| Newline | ⇧⏎ or ⌘⏎ |
| Copy result | ⇧⌘C |
| History | ⌘Y |
| Settings | ⌘, |
| Back / close | Esc |

Show/hide, Translate, Newline, Copy, History, and Back/close are rebindable under
Settings → Shortcuts. Asking for an online second opinion reuses Translate; ⌘, for
Settings is fixed.

## Build

Use Xcode 26.6 or newer to compile the macOS 26 APIs and isolated deinitializers.
The built app still supports macOS 14 and later; SDK requirements and runtime requirements differ.

```bash
./build.sh                        # builds build/Tusi.app for the current arch
TUSI_ARCH=universal ./build.sh    # universal binary (arm64 + Intel)
./build.sh install                # build and install to /Applications (debug loop)
./build.sh install --open         # build, install, and launch it
./build.sh release                # arm64 + universal release zips into dist/
```

The default version/build number comes from `VERSION`; CI or release scripts can override
it with `TUSI_VERSION` and `TUSI_BUILD_NUMBER`.

Pure Swift + SwiftUI + AppKit, with no third-party dependencies. `build.sh`
signs with a local code-signing identity when available (so Keychain access
survives rebuilds), and falls back to ad-hoc signing otherwise. For public
distribution, use a Developer ID identity and notarize the resulting app.

The dev signing identity (`Tusi Dev Signing`) lives in the login keychain,
which macOS unlocks automatically at login. `build.sh` verifies the signature
after signing. A legacy override exists for machines that keep the identity in
a dedicated keychain:

```bash
TUSI_SIGN_KEYCHAIN=~/Library/Keychains/tusi-dev.keychain-db \
TUSI_SIGN_KEYCHAIN_PW_FILE=~/.dsh/tusi-signing.pw ./build.sh
```

Local installs prefer a stable Team-ID identity. Keeping only the same self-signed certificate
does not guarantee that Keychain authorization survives a changed binary; see the partition-ID
explanation above. Public archives use the separate distribution identity.

### Diagnosing panel height

The panel's height is not one measurement — the result text sizes the result viewport,
which sizes the content, which sizes the window — and every hop is a preference feeding a
`@State` that feeds the next hop's frame. SwiftUI does not promise to redeliver a
preference for the layout its own state write caused, so a hop can go quiet, and when one
does the window stays sized for the previous result.

The panel therefore checks itself. Once a resize settles it asks AppKit what the content
actually measures — a question no missing preference can corrupt — grows the window if it
is too small, and writes out the last 48 measurements. That runs in every build and prints
nothing while the panel behaves, so the first move is to look for the record, not to turn
anything on:

```bash
/usr/bin/log show --predicate 'subsystem == "com.tusi.app"' --last 1h --style compact | grep height
```

A `height mismatch:` line followed by `height chain:` lines is the panel catching itself:
the chain is in order, so the hop that stopped reporting is the one that is broken. Nothing
at all means the panel and its content agreed every time.

For a live per-hop stream while reproducing something by hand:

```bash
defaults write com.tusi.app heightDiagnostics -bool true   # then relaunch Tusi
defaults delete com.tusi.app heightDiagnostics             # off again
```

Use the full path `/usr/bin/log`: a shell function named `log` is a common thing to have,
and it will silently eat the arguments.

## License

MIT
