# PocketAgent

A native iPhone assistant with multiple conversations, configurable model
providers and phone automation through AgentKit, idevice and WebDriverAgent.
The model loop and phone tools run on the iPhone. Model inference uses the API
provider you configure.

## Installation

[![Download IPAs](https://img.shields.io/badge/Download-IPAs-6554E8?style=for-the-badge)](https://github.com/Borealin/PocketAgent/releases/latest)
[![Add source to AltStore](https://img.shields.io/badge/AltStore-Add_source-38A169?style=for-the-badge)](https://altstore.io/source/raw.githubusercontent.com/Borealin/PocketAgent/main/Distribution/source.json)

Recommended: [add the source](#altstore-classicsidestore-source) and install
**PocketAgent** and **PocketAgent Automation** from it. Both are required for
phone tools. To install manually:

1. Install [AltStore Classic](https://altstore.io/) or
   [SideStore](https://docs.sidestore.io/).
2. Open [the latest release](https://github.com/Borealin/PocketAgent/releases/latest)
   in Safari. Download both `PocketAgent-<version>.ipa`
   and `PocketAgent-WDA-<version>.ipa` to Files.
3. Import and sign **both** IPAs in your sideloading app. The second one is
   **PocketAgent Automation**, required for phone tools. Keep both installed
   and refresh their signatures using the sideloading app.
4. Enable Developer Mode, configure the local VPN and import this phone's
   **idevice RP pairing record**. In PocketAgent's device settings, enter the
   installed Automation companion's bundle ID; signing can change it.
5. Add your API provider and model in Settings, then start a conversation.

For an existing installation, update using the same signing account and bundle
IDs to retain its local data. Do not delete the app first. A separately signed
installation needs its own credentials and device configuration; portable
conversations can be imported through the same iCloud Drive sync folder.

### AltStore Classic/SideStore source

The public feed contains **PocketAgent** and **PocketAgent Automation** and is
updated automatically after a release. Open the button below on your iPhone to
add the source in AltStore Classic. For SideStore, copy the source URL into its
Sources screen. No GitHub sign-in is required.

[![Add source to AltStore](https://img.shields.io/badge/AltStore-Add_source-38A169?style=for-the-badge)](https://altstore.io/source/raw.githubusercontent.com/Borealin/PocketAgent/main/Distribution/source.json)

```text
https://raw.githubusercontent.com/Borealin/PocketAgent/main/Distribution/source.json
```

After adding the source, install both apps from it. New releases appear as
updates in the sideloading app. Adding a source still requires signing and the
initial device setup described below.

This uses the [official AltStore deep-link format](https://faq.altstore.io/developers/download-on-altstore-badge).
The feed targets Classic/SideStore; AltStore PAL notarization and LiveContainer
guest execution are separate, unverified paths.

## Requirements

- iOS 26 or later, Developer Mode enabled.
- PocketAgent and its separate **PocketAgent Automation** companion installed
  with a development-capable signature, such as AltStore Classic or SideStore.
- An idevice RP pairing property list created during initial setup. An ordinary
  USB/Lockdown pairing record has a different format and cannot replace it.
- A local VPN exposing the device's developer services, such as LocalDevVPN.
- An API provider supporting tool calls. Image input is optional; select the
  capability only for models that support it.

The first pairing, installation and system authorization require setup. After
setup, a conversation can invoke phone tools without a connected computer.
Keep the local VPN connected. iOS can require the device passcode when enabling
UI automation; enter it only in the system page on the phone.

## Conversations and providers

Use the list icon to open conversations and Settings. Tap the chat title to
rename it, or use the conversation's menu in the list. The top-right icon starts
a new conversation. The model chip above the input chooses this conversation's
provider and model.
The concrete model name appears first; the picker shows API information beneath it.
Settings → 外观 chooses 跟随系统, 浅色 or 深色; the choice stays on this device.

The input grows to six lines and accepts up to six images from Photos, the
camera or the system paste button. Images can be removed or previewed before
sending; image-only messages require a model configured to accept images.
Text-only models show an explicit choice before sending text without its images.
Photos are normalized and stored locally without their source EXIF/GPS metadata.

Replies render headings, lists, quotes, code and tables. Code has a copy button;
wide tables scroll horizontally. Local images open a full-screen preview.
Remote Markdown images load over HTTPS only after tapping Load. Streaming
follows the bottom while you are there and offers a return-to-bottom button
while you read earlier content. Phone steps are folded into an expandable
timeline with outcomes and optional details.

During a turn, a status strip shows the actual model/tool phase, current app or
action, completed steps and elapsed time. The system task surface shows the same
phase while another app is foreground. Stop remains separate from the input,
which can accept an additional instruction for the active turn. Other
conversations join the serial queue and display their waiting position.

Open the provider page to add a service name, API format, complete inference
URL, API key and one or more model IDs. Supported formats are OpenAI Chat
Completions, OpenAI Responses, Anthropic Messages and Gemini. A model catalog
URL is optional; manual model IDs work without one. URLs must use HTTPS and
must not contain credentials.

Choose a provider and model for each conversation. Accepted turns capture
their selection and credential before joining the serial phone action queue.
Later configuration changes apply to subsequent turns. Conversations preserve
their own history and model attribution. Interrupted phone actions are never
replayed after restarting the app.

In device settings, import this phone's pairing record and configure the local
VPN address, port and installed automation runner's bundle ID. Sideloading tools
can change bundle IDs during signing: use the ID of the companion actually
installed on your device.

API keys live in the local Keychain. Pairing records stay in protected local
application storage and are excluded from backup. Diagnostic file output is
disabled by default; enabling the native log takes effect after relaunch.
Treat pairing records as credentials. A provider address changed by sync cannot
send a saved key to a new host: enter the key again on that device to authorize
the new address.

## iCloud Drive synchronization

Choose a folder in **iCloud Drive** with the system folder picker, then sync.
Choose that same folder on another device to share conversations and nonsecret
provider configuration. Each device needs its own API keys, pairing record,
runner settings and folder permission.

Portable snapshots contain conversation text, tool calls/results, model
selection, image-presence metadata and nonsecret provider settings. Image bytes,
screenshots, keys, pairing records, drafts and running jobs are kept local.
An image synced from another device appears unavailable unless its bytes are
already on this device. A synced conversation
does not trigger phone actions. Concurrent divergent histories are preserved as
conflict copies; deletions retain tombstones to prevent stale devices restoring
deleted items. Unknown snapshot versions fail without overwriting the file.
Automatic copies follow their original conversation's title and model until
edited. Local text written during a sync that deletes its conversation is kept
in a new conversation. Deletions otherwise take precedence over stale snapshots,
including offline edits present before that sync starts.

Synchronization happens when the app requests it; iCloud's file transport is
eventual. An active turn is deferred until it completes. This uses a user-chosen
folder rather than CloudKit entitlements, so ordinary personal sideload signing
does not need an app-owned iCloud container.

## Projects, rules and scripts

The folder chip beside the model chip chooses the conversation's project. A
project is an app-local directory; create one, import a folder from Files, or
manage files in Settings → 项目与规则 (browse, create, edit text, import,
export a copy, delete). Accepted turns use the project selected when they were
sent. Projects, rules and script runtimes are not synchronized.

Each turn's model context includes the global AGENTS.md (Settings → 全局
AGENTS.md), the project's root AGENTS.md and a catalog of skills
(`skills/<name>/SKILL.md` globally, `.agents/skills/<name>/SKILL.md` in a
project; name and description from front matter). The model reads a skill's
full text with `read_skill`. Nested AGENTS.md files are not loaded.

With a project selected the model can list, read, search, write and patch its
files; paths are relative to the project root and symbolic links are never
followed. `http_request` sends any method, headers and text/JSON body to public
HTTPS hosts only (plain `http://` is refused because it cannot prove which host
answered), with bounded responses and a whole-request time limit. Local and
private addresses, and names resolving to them, are refused before connecting
and on each redirect; TLS proves the hostname, not that its address is public,
so this is not a guarantee against a server that changes its DNS answer.
Neither tool asks for confirmation step by step. Scripts have their own guest
network for pip, npm and similar tools, limited to public addresses and never
the phone's WebDriverAgent/lockdown ports.

`run_script` runs bash, sh, Python 3 or Node.js on the phone in an embedded iSH
Linux (x86 Alpine, emulated; noticeably slower than native code). The project is
mounted at `/workspace` and is the only app data the guest can see. Results
report the real exit status and separate stdout/stderr; full output stays under
`.pocketagent/runs/` in the project. Scripts can operate the phone with
`pocketagent-phone <tool> '<json>'`, which goes through the same validation and
serial action queue as the model's phone tools; failures are never retried
automatically. Stopping a turn revokes that permission first, then interrupts and
finally kills the script's processes. The first script imports the Linux root
filesystem (excluded from backup), which takes extra time. A project used by a
queued or running turn cannot be deleted until that turn ends.

The app binary includes the iSH runtime and the Linux kernel and is therefore
distributed under the GNU GPL version 2 (iSH is dual-licensed GPL-3.0/GPL-2.0
for this purpose; see THIRD_PARTY_NOTICES.md). Each release publishes its
complete corresponding source next to the IPA.

## Build

On macOS, install Xcode 26.2 or later, XcodeGen, Rust 1.95.0, meson and lld, plus
Docker able to run linux/386 containers for the script rootfs. Select the full
Xcode developer directory, then run from the repository root:

```sh
brew install xcodegen meson lld
rustup toolchain install 1.95.0 --profile minimal
rustup default 1.95.0
env -u SDKROOT swift test
python3 -m unittest discover -s Tests/DistributionTests
python3 -m unittest discover -s Tests/RuntimeTests
env -u SDKROOT python3 Scripts/build.py
python3 Scripts/distribution.py
```

The build fetches exact revisions from `dependencies.json`, applies the local
idevice patch, builds its static iOS library, builds the patched iSH runtime and
the pinned Alpine rootfs (`Scripts/ish_runtime.py`), archives the app and builds
the automation companion. `dist/` also receives the GPL corresponding source
archive (repository snapshot, pinned iSH/Linux/libarchive archives, Swift package
and idevice sources, vendored Rust crates). The rootfs build pins every Alpine
package in `dependencies.json` and fails if the repository can no longer supply
that exact closure; `python3 Scripts/ish_runtime.py verify-rootfs` checks an
existing archive. Dependencies and generated products stay in ignored
directories. `project.yml` is the XcodeGen source of truth.

`dist/` contains both IPAs and `SHA256SUMS`. Release IPAs use ad-hoc signatures,
contain no provisioning profile and must be re-signed before installation.
The inspector verifies bundle metadata, signatures and identity/data exclusions
before generating `Distribution/source.json` from the actual IPAs.

For a device build, pass an untracked signing JSON file explicitly:

```sh
env -u SDKROOT python3 Scripts/build.py --development /path/to/local-signing.json
```

The file contains `identity`, `team`, `profile`, `bundleID` and `runnerBundleID`.
`legacyKeychainService` is an optional migration override for an existing local
installation. Use a development profile covering the bundle IDs you install.
Development artifacts go to `build/development/` and are never used to generate
the public source.

## Releases and AltStore sources

The release workflow builds both IPAs and uploads them with checksums. A matching
`v<version>` tag publishes a GitHub release and updates the Classic source on
`main`, retaining older releases. Version/build settings live in
`Distribution/config.json`.

See [Installation](#installation) for IPA downloads and the source URL. The
repository, feed, icon and release assets are public. Each release includes both
IPAs, checksums and complete corresponding source; users can subscribe and
download without a GitHub account.

## Development

Read [AGENTS.md](AGENTS.md) and [the engineering design](docs/engineering.md).
Core tests cover migrations, frozen model selection and portable merge rules;
distribution tests cover feed updates. Real-device checks are required for phone
automation and actual iCloud folder access. Build or unit-test success alone does
not establish those behaviors.

Licensed under MIT. See [third-party notices](THIRD_PARTY_NOTICES.md).
