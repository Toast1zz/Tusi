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
- Optional auto-copy to clipboard, and a bounded local history of recent translations
- Smart quotes on output, leaving code spans and blocks untouched
- Every shortcut is rebindable
- The result appears complete, in one step — no token-by-token flicker, and local and remote
  models behave identically. Adapts to light/dark; Liquid Glass on macOS 26+

## Requirements

- macOS 14+
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
- Provider preference order (optional) — OpenRouter's `provider.order`, e.g. `novita`. It is a
  preference, not a restriction: OpenRouter may still fall back to a provider you did not list.

There are two remote profiles, primary and backup, plus a third slot for a local model
(Ollama, LM Studio, llama.cpp-server). How they are used is one section on the Settings
page, "翻译路线", with two questions:

- **从哪开始** — the local model, or an online service. Starting local does not mean local
  only: the local answer arrives first, and one more ⏎ asks an online service for its own
  version. Both are kept, and a small label under the result switches between them.
- **两套在线服务** — 主用优先 (the backup takes over only when the primary fails) or
  同时请求 (both are asked at once and the first usable answer wins, which doubles what you
  are billed per translation). The second option is offered only when both slots are remote:
  a loopback slot would win on network latency alone, which says nothing about the answer.

Each question appears only when it is a real choice, and a primary request that fails
before producing any output is always retried on the backup. API keys are stored in the
Keychain, not on disk, and each profile has a "test connection" button.

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

Every row above is rebindable under Settings → Shortcuts.

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

Signing with the same certificate on every rebuild keeps the Keychain "Always Allow" authorization valid — ad-hoc builds change the signature's cdhash each build and re-prompt for the API key on every install, so keep a stable identity around for local builds.

## License

MIT
