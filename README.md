# PocketAgent

A native iPhone assistant with multiple conversations, configurable model
providers and phone automation through AgentKit and idevice. This branch defaults
to DDI services; WebDriverAgent remains selectable in phone settings.
The model loop and phone tools run on the iPhone. Model inference uses the API
provider you configure.

## Installation

This branch's DDI backend uses the main app, Developer Mode, an RP pairing record
and a local VPN. It needs no Automation companion or XCTest authorization.
Select **WDA** in Settings → 手机操作配置 to use the companion instead. Backend
selection is captured when a turn is queued. DDI currently accepts verified
portrait display geometry; switch explicitly to WDA for other layouts. Text input
writes the device clipboard through CoreDevice, checks its actual UTF-8 contents,
then pastes through the owned HID keyboard without activating PocketAgent. The
target app can request paste permission; rejected or unconfirmed insertion is
reported rather than replayed.
DDI also offers `press_keys` for model-controlled physical keys and IME candidates.
The phone setup's clipboard switch permits or forbids the paste path and known
clipboard shortcuts; permission and backend are captured when the turn is queued.
`type_text` retains its required parameters and defaults to paste. Optional
`method: "ax"` replaces a nonempty ordinary TextField/SearchField value without
clipboard access; use it only for authorized whole-field replacement and inspect
the App response because some validation callbacks may not fire. AX excludes
password fields, TextView and caret insertion. AX does not promise focus transfer;
confirm target focus before submitting a keyboard action. Uncertain effects are never replayed. Keyboard calls return the actual screen
without assuming the layout or claiming that composition has committed.
The published candidate instructions below describe the earlier WDA release;
the DDI change has not been published to that feed.

The source offers both apps from the
[v0.3.7 candidate](https://github.com/Borealin/PocketAgent/releases/tag/candidate-0.3.7).
This update adds installed-app lookup and opening by the exact name reported
by the device, with explicit ambiguity handling and no guessed bundle IDs.
Phone tools support observed search fields, ordinary scrolling and coordinate
swipes for nested lists or edge-back gestures. Changed foreground apps and stale
nodes return a fresh observation when possible; interrupted actions are never
replayed. System search uses the same observed taps, swipes and text input as other pages. The advanced endpoint hint
always shows the embedded default even when an override is saved.

On the tested iPhone 15 Pro, initial developer TCP connections are refused when
cellular is the only network. A tunnel established with cellular off supported
phone operations after restoring data in a wired diagnostic test; survival of
a live prepared tunnel after USB removal remains unverified. No tested VPN
configuration has fixed direct cellular-only startup. This remains a prerelease.

The v0.3.0 Automation packaging caused a provisioning-profile error. Versions
0.3.1 and later package the complete test module as a nested framework.
Update both apps when leaving 0.3.0; do not mix the old companion with the new app.

[![Download IPAs](https://img.shields.io/badge/Download-IPAs-6554E8?style=for-the-badge)](https://github.com/Borealin/PocketAgent/releases/tag/candidate-0.3.7)
[![Add source to AltStore](https://img.shields.io/badge/AltStore-Add_source-38A169?style=for-the-badge)](https://altstore.io/source/raw.githubusercontent.com/Borealin/PocketAgent/main/Distribution/source.json)

Recommended: [add the source](#altstore-classicsidestore-source) and install
**PocketAgent** and **PocketAgent Automation** from it. Both are required for
phone tools. To install manually:

1. Install [AltStore Classic](https://altstore.io/) or
   [SideStore](https://docs.sidestore.io/).
2. Open [the v0.3.7 candidate](https://github.com/Borealin/PocketAgent/releases/tag/candidate-0.3.7)
   in Safari. Download both `PocketAgent-<version>.ipa`
   and `PocketAgent-WDA-<version>.ipa` to Files.
3. Import and sign **both IPAs from the same release** in your sideloading app. The second one is
   **PocketAgent Automation**, required for phone tools. Keep both installed
   and refresh their signatures using the sideloading app.
4. Enable Developer Mode, configure the local VPN and import this phone's
   **idevice RP pairing record** using the [Mac setup guide (中文)](docs/pairing-zh.md).
   Leave the advanced Automation Bundle ID empty for automatic matching.
   A manual override is available if your signing layout differs.
5. Add your API provider and model in Settings, then start a conversation.

For an existing installation, update using the same signing account and bundle
IDs to retain its local data. Do not delete the app first. A separately signed
installation needs its own credentials and device configuration; portable
conversations can be imported through the same iCloud Drive sync folder.
When upgrading from v0.3.0 to v0.3.1, update both apps: the test module's location
changed, so mixing these versions does not support phone automation.

### AltStore Classic/SideStore source

The public feed contains **PocketAgent** and **PocketAgent Automation**, currently
offering the **0.3.7 candidate (build 10)** for both apps. Stable releases update
the feed automatically; this candidate is included explicitly for device validation.
Open the button below on your iPhone to
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
- PocketAgent installed with a development-capable signature, such as AltStore
  Classic or SideStore. **PocketAgent Automation** is needed only for WDA.
- An idevice RP pairing property list created during initial setup. An ordinary
  USB/Lockdown pairing record has a different format and cannot replace it.
- A local VPN exposing the device's developer services, such as LocalDevVPN.
- An API provider supporting tool calls. Image input is optional; select the
  capability only for models that support it.

The first pairing, installation and system authorization require setup. After
setup, a conversation can invoke phone tools without a connected computer.
Keep the local VPN connected and the phone unlocked. For WDA, iOS can require the
device passcode when enabling UI automation; enter it only in the system page on
the phone. DDI does not launch XCTest.

If connection checks fail only on cellular, open Settings → 手机操作配置 →
蜂窝连接恢复. Temporarily disable cellular and disconnect Wi-Fi while leaving
LocalDevVPN connected, then tap **准备蜂窝模式连接**. After **连接已保留** appears,
restore cellular and send a new message. The real RP tunnel is retained for at
most 120 seconds (iOS may end the background allowance sooner) and is consumed
by the next phone operation. Ordinary **检查连接** releases its temporary tunnel;
it does not prepare a later turn. Pure chat/file/network turns do not consume
the prepared connection. Expiry, Stop, explicit release and device-setting
changes discard it. An expired phone operation is never replayed automatically.
The default path label can show unavailable while the local VPN still works.


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

Open Settings → 模型服务 to choose a connection preset, enter one **Base URL**
and your API key, then tap **连接并加载模型**. Presets support OpenAI-compatible
Chat Completions, OpenAI Responses, Sub2API, Anthropic Messages and Gemini. The
app derives the inference and `/models` endpoints, displays loading/errors, and
lets you search the returned models. A refresh retains existing manual models
and image capabilities. Model IDs can also be added manually when a catalog is
unavailable. URLs must use HTTPS and must not contain credentials.

For Sub2API, use the base supplied by your gateway and the protocol supported
by your key's group. Common routes use `/v1`; Antigravity uses explicit
`/antigravity/v1` for Messages or `/antigravity/v1beta` for Gemini. The Sub2API
preset starts with Responses; change the protocol if your group requires it.
Existing addresses and keys stay unchanged. Advanced custom addresses remain
available for services with different inference and catalog routes.

Choose a provider and model for each conversation. Accepted turns capture
their selection and credential before joining the serial phone action queue.
Later configuration changes apply to subsequent turns. Conversations preserve
their own history and model attribution. Interrupted phone actions are never
replayed after restarting the app.

Settings → 手机操作配置 selects DDI or WDA, then walks through connecting
LocalDevVPN and importing this phone's **RP pairing file** from Files. The
easiest first setup uses the upstream **idevice_pair** GUI: choose the USB phone,
select **Remote pairing**, then **Create → Validate → Save to file…**.
After Create, the phone may show another Trust prompt for the new
`idevice_pair` identity even when USB trust is already established; complete
that prompt and any passcode entry on the phone before Validate.
Another compatible Mac can create the record; this does not depend on your
Apple ID or IPA signing account.

[![Mac pairing guide](https://img.shields.io/badge/Mac-配对教程-6554E8?style=for-the-badge)](docs/pairing-zh.md)
[![Download pairing tool](https://img.shields.io/badge/Download-Mac配对工具-38A169?style=for-the-badge)](https://github.com/jkcoxson/idevice_pair/releases/download/v1.1.0/idevice_pair--macos-universal.dmg)

The [Chinese guide](docs/pairing-zh.md) covers USB trust, the GUI, AirDrop and
both 0.3.1/0.3.2 import locations. The official DMG supports Apple Silicon and
Intel without Rust, Python or Xcode. The optional
[download script](Scripts/download_pairing_tool.command) downloads that fixed
release, verifies SHA-256 and opens its DMG; it does not install software or
generate a record. The GUI prepares developer services and enables wireless
debugging on the selected phone. Validate checks the RP record against that
phone; Automation installation and XCTest system authorization are separate.

For existing CLI users, the guide also includes the trusted-USB command with
explicit device selection, a unique host name and a fresh output directory.
Use that command when generating a new record.

Transfer the file to the iPhone using AirDrop or Files. A SideStore/Jitterbug
USB pairing file has a different format; import explains that error and retains
the previous working record. **检查连接** checks the saved pairing/VPN settings
without opening another app. The local VPN address, port and Automation bundle
ID are under advanced settings. Sideloading can change bundle IDs: use the ID of
the companion actually installed on your device.

API keys live in the local Keychain. Pairing records stay in protected local
application storage and are excluded from backup. Diagnostic file output is
disabled by default; enabling the native log takes effect after relaunch.
Treat pairing records as credentials. A provider address changed by sync cannot
send a saved key to a new host: enter the key again on that device to authorize
the new address.

## iCloud Drive synchronization

Tap **启用 iCloud 同步**, then choose a location in **iCloud Drive** once with
the system folder picker. The app creates/reuses a `PocketAgent` folder there
and remembers its permission; later app openings sync automatically. Existing
installations keep their selected folder. **使用已有同步文件夹 / 更改同步位置**
selects an exact folder without creating another child. Choose the same
`PocketAgent` folder on another device to share conversations and nonsecret
provider configuration. Local folders do not sync across devices. Each device
needs its own API keys, pairing record, runner settings and folder permission.

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
finally kills the script's processes. On app opening the bundled Linux root
filesystem initializes automatically (excluded from backup), and the app
actually runs Bash, Python and Node startup checks. Settings → 脚本环境 shows
preparing, checking, ready or a specific restart-required error. No JIT or
runtime download is needed. The initial preparation takes extra time. A project used by a
queued or running turn cannot be deleted until that turn ends.

The app binary includes the iSH runtime and the Linux kernel and is therefore
distributed under the GNU GPL version 2 (iSH is dual-licensed GPL-3.0/GPL-2.0
for this purpose; see THIRD_PARTY_NOTICES.md). Each release publishes its
complete corresponding source next to the IPA.

## Build

Bootstrap keeps patched idevice sources under `.deps/idevice-pocketagent/`, keyed
by pinned revision and the digest of `Native/idevice.patch`. Changing the patch
creates a new checkout; an existing legacy `.deps/idevice` is left untouched.
Managed checkouts with unknown local edits are refused rather than reset. Put
maintained native changes in `Native/ddi` or `Native/idevice.patch`.

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
Use a development profile covering the bundle IDs you install.
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
