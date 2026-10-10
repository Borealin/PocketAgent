# PocketAgent

A native iPhone assistant with multiple conversations, configurable model
providers and phone automation through AgentKit, idevice and WebDriverAgent.
The model loop and phone tools run on the iPhone. Model inference uses the API
provider you configure.

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
selection and nonsecret provider settings. Screenshots, attachments, keys,
pairing records, drafts and running jobs are kept local. A synced conversation
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

## Build

On macOS, install Xcode 26.2 or later, XcodeGen and Rust 1.95.0. Select the full
Xcode developer directory, then run from the repository root:

```sh
brew install xcodegen
rustup toolchain install 1.95.0 --profile minimal
rustup default 1.95.0
env -u SDKROOT swift test
python3 -m unittest discover -s Tests/DistributionTests
env -u SDKROOT python3 Scripts/build.py
python3 Scripts/distribution.py
```

The build fetches exact revisions from `dependencies.json`, applies the local
idevice patch, builds its static iOS library, archives the app and builds the
automation companion. Dependencies and generated products stay in ignored
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

When this repository is public, its source URL is:

```text
https://raw.githubusercontent.com/Borealin/PocketAgent/main/Distribution/source.json
```

A private GitHub repository requires authentication for both source and assets;
it cannot serve an anonymous AltStore subscription. While private, download the
release IPAs through your authenticated GitHub account and install them manually.
This feed targets AltStore Classic/SideStore. AltStore PAL notarization and
LiveContainer guest execution are separate distribution/runtime paths.

## Development

Read [AGENTS.md](AGENTS.md) and [the engineering design](docs/engineering.md).
Core tests cover migrations, frozen model selection and portable merge rules;
distribution tests cover feed updates. Real-device checks are required for phone
automation and actual iCloud folder access. Build or unit-test success alone does
not establish those behaviors.

Licensed under MIT. See [third-party notices](THIRD_PARTY_NOTICES.md).
