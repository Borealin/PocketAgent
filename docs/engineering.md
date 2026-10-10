# PocketAgent engineering

## Requirements and scope

Native provider management on a dedicated page, provider/model selection per
conversation, iCloud Drive synchronization of portable data, reproducible IPA
builds and AltStore Classic/SideStore source publication. Initial repository is
private Borealin/PocketAgent. Existing installed conversations and local API
settings must migrate intact. Siri and arbitrary on-phone XCTest compilation
remain outside this iteration.

## Decisions

Retain pinned AgentKit 8108c9bb87c546860cfc1769571e115af919fe8a and the verified
native idevice/WDA execution path. Use a small Codable store with Keychain
credentials, per-session selection and frozen queued-turn configuration.

Use a folder selected via the system document picker for iCloud Drive. Avoid an
app-owned ubiquity container because personal/free sideload signing cannot
reliably provision that capability. Sync only sessions and nonsecret provider
configuration; no keys, pairing records, screenshots, logs, selected UI state,
queued/running actions or drafts. Apply coordinated writes, deletion tombstones
and deterministic conflict preservation. Sync never executes phone work.

Conflict copies record their parent conversation. Automatic copies inherit the
parent's merged title and model selection; editing a copy makes that metadata
independent. Copy IDs derive from the parent ID and branch tip. Only unedited
copies fully covered by a longer history can be pruned. Deletion tombstones win
over stale snapshots. Text written locally while a deletion is being synchronized
is preserved under a new conversation ID; offline edits already included in the
round's starting snapshot remain subject to the deletion.

Read every unresolved NSFileVersion inside the coordinated write, merge them
with current and local data, then write before resolving versions. Invalid or
newer snapshots stop the round without overwriting them. A connection generation
prevents a completed round from an old folder applying after a folder change.

Credentials are bound to their entered HTTPS origins in local provider storage.
A synchronized change to another origin requires entering the key again before
inference or catalog requests. Local endpoint edits explicitly update the
binding. Keys and bindings are never included in portable snapshots. Diagnostic
file output and screenshots default to off; the native log toggle takes effect
on the next launch.

Build an ordinary Xcode project from XcodeGen plus pinned dependencies. IPA
artifacts carry no development profile, team identity, credential or device
record. A separate WDA companion IPA is necessary for phone automation. The
AltStore Classic feed lists real versions, sizes, hashes and permissions. PAL
notarization and LiveContainer guest execution are separate and untested paths.

## Architecture and compatibility

App: SwiftUI sessions/provider/sync views. AgentKit: model protocols and agent
loop. Native: Rust FFI tunnel/DDI/runner startup, then localhost WDA tools.
Run configuration is captured before enqueue; changing a session selection does
not alter work already accepted. Existing transcript event order and tool result
IDs are preserved. Restart interrupts active work, never replays it.

Legacy endpoint/model and Keychain settings migrate once; production defaults
contain no private gateway or company identity. Local build overrides preserve
the installed test app identity without committing them. Device pairing import
and runner/VPN settings are local to each device.

## Delivery and rejected alternatives

Owner: Codex integrator and Opus 5.5 app developer.
Verify migrations, session isolation, provider selection capture, sync deletion
and concurrent history conflicts, build/install and actual model/tool execution.
IPA/source and repository scans precede GitHub push. Success-only evidence stays
in the parent workspace work/ directory. Synchronization runtime claims require
actual iCloud folder access; multi-device convergence requires two-device proof.

## Confirmed integration problems and fixes

WDA's Release build-for-testing embeds debug symbol bundles and linker object
paths. Packaging removes the debug bundles, strips debug records while retaining
runtime symbols, maps compiler source paths and signs the prepared copy. IPA
inspection rejects remaining local paths and development identities.

A release tag starts from an older source snapshot than current main. Publishing
merges against current main and keeps all earlier versions in numeric order.
The freshly inspected CI artifact replaces metadata for its own version/build,
so a locally generated source cannot leave the wrong checksum for CI assets.

Independent merge review reproduced order-dependent copy metadata and deletion
during a local append losing text. Parent metadata inheritance, deterministic
copy identities and preservation of the concurrent local edit fix these cases.
An additional regression showed that prefix pruning dropped a user-edited
copy's title and model; pruning is now restricted to unedited automatic copies.
Regressions cover three-way grouping/replay, differing branch depths, metadata
edits and randomized branch combinations. File transport and real NSFileVersion
conflict resolution still require separate runtime verification.

## Primary references

- [AltStore Classic source schema](https://faq.altstore.io/developers/make-a-source)
- [EHPanda packaging workflow](https://github.com/EhPanda-Team/EhPanda/blob/main/.github/workflows/deploy.yml)
- [LiveContainer installation](https://livecontainer.github.io/docs/installation)
- [Apple directory access](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
- [Apple document version conflicts](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocumentBasedAppPGiOS/ResolveVersionConflicts/ResolveVersionConflicts.html)

Rejected alternatives: CloudKit/ubiquity containers require signing capabilities
that ordinary AltStore personal accounts cannot assume. A new generic database
or storage abstraction is unnecessary for this scope. Secret synchronization is
not part of portable conversation data.
