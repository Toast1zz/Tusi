# Tusi

A menubar translator for macOS. Type Chinese and get English; type anything else and get Chinese. The direction is detected automatically, so there is nothing to select.

## Features

- Automatic direction, detected locally by script (works on mixed Chinese/Latin text, no network round-trip)
- Explicit targets when you want them: English, Chinese, Japanese, Korean
- Menubar panel, summoned with ⌥Space
- BYOK — any OpenAI-compatible endpoint (DeepSeek, OpenRouter, SiliconFlow, Ollama, …)
- Three slots: primary and backup online services, plus a local-model slot
- Start local and press ⏎ again for an online second opinion — both answers are kept, and
  the clipboard follows whichever one you are looking at
- Two online services, used either primary-first or asked at the same time
- Three tone presets (casual / standard / formal)
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
- Provider preference order (optional) — OpenRouter's `provider.order`, e.g. `novita`. It is a
  preference, not a restriction: OpenRouter may still fall back to a provider you did not list.

There are two remote profiles, primary and backup, plus a third slot for a local model
(Ollama, LM Studio, llama.cpp-server). How they are used is one section on the Settings
page, "翻译路线", with two questions:

- **从哪开始** — the local model, or an online service. Starting local does not mean local
  only: the local answer arrives first, and one more ⏎ asks an online service for its own
  version. Both are kept, and a small label under the result switches between them.
- **两套在线服务** — 主用优先 (the backup takes over only when the primary fails) or
  同时请求 (both are asked at once and the first usable answer wins; both services may charge,
  and the cost depends on their rates and cancellation timing). The second option is offered only when both slots are remote:
  a loopback slot would win on network latency alone, which says nothing about the answer.

Each question appears only when it is a real choice, and a primary request that fails
before producing any output is always retried on the backup. API keys are stored in the
Keychain, not on disk, and each profile has a "test connection" button.

Connection tests use the same protocol negotiation as real translations and send at most
two short requests. Automatic update checks run at startup and every six hours while enabled.

History retains both local and online versions, including the host and model that answered.
Each archived text field is limited to 4,000 characters and 32 KB; truncated versions stay
marked. Right-click a record to delete it, or clear the list; deletion can be undone for
ten seconds. History and draft saving can be disabled independently in Settings. Turning
off saving deletes the corresponding saved data; clearing the input draft does not delete
history. Text is stored locally with owner-only file permissions, without encryption.

Two more fields, both collapsed by default because most setups never need them:

- **附加要求** — one instruction added to every request, whichever profile answers it. This
  is where a glossary entry ("commit 统一译作「提交」"), a house style, or a name that must
  survive untranslated goes.
- **输出协议** (under 高级选项, per profile) — 自动 asks for structured output and, the first
  time a server turns out not to support it, falls back to plain text and retries that same
  request. Pin it to 纯文本兼容 for an endpoint that advertises the capability but does not
  honour it. The result is identical either way; only the shape of the request changes.

If a freshly installed build asks you to authorize the API keys again, run
`./build.sh keychain-unpin` once. macOS guards a Keychain item with a partition list whose
entries are `teamid:` for an app signed by an identity carrying a Team ID and `cdhash:` for
one that is not — and a cdhash changes with every build, so a self-signed app looks like a
new application each time no matter how stably it is signed. Local builds therefore prefer
an `Apple Development:` identity if one is present; the command above repoints an existing
item at that Team ID. Release archives stay on the anonymous self-signed identity, since a
Development certificate carries the developer's name and email. One note on launch-at-login: before macOS completes its first unlock after boot, the Keychain is not yet accessible, so a login-item launch that early may briefly see no API key — it recovers automatically once the system is unlocked.

## Shortcuts

| Action | Key |
|---|---|
| Show / hide panel | ⌥Space |
| Translate | ⏎ |
| Retranslate online (after a local answer) | ⏎ again |
| Newline | ⇧⏎ or ⌘⏎ |
| Copy result | ⇧⌘C |
| Settings | ⌘, |
| Back / close | Esc |

Every row above is rebindable under Settings → Shortcuts, except ⌘, which the panel
handles directly.

## Build

```bash
./build.sh                        # builds build/Tusi.app for the current arch
TUSI_ARCH=universal ./build.sh    # universal binary (arm64 + Intel)
TUSI_VERSION=1.4.3 TUSI_BUILD_NUMBER=12 ./build.sh
./build.sh install                # build and install to /Applications (debug loop)
./build.sh install --open         # …and launch it
./build.sh release                # arm64 + universal release zips into dist/
```

The default version/build number comes from `VERSION`; CI or release scripts can override
it with `TUSI_VERSION` and `TUSI_BUILD_NUMBER`.

Pure Swift + SwiftUI + AppKit, no third-party dependencies. `build.sh` signs with a local code-signing identity when one is available (so Keychain access survives rebuilds), and falls back to ad-hoc signing otherwise. For public distribution, use a Developer ID identity and notarize the resulting app.

The dev signing identity (`Tusi Dev Signing`) lives in the login keychain, which macOS unlocks automatically at login — builds never ask for a keychain password, and `build.sh` verifies the signature after signing. A legacy override exists for machines that keep the identity in a dedicated keychain:

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
