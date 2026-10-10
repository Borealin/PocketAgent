# PocketAgent engineering

## Requirements and scope

Native provider management on a dedicated page, provider/model selection per
conversation, iCloud Drive synchronization of portable data, reproducible IPA
builds and AltStore Classic/SideStore source publication. Initial repository is
private Borealin/PocketAgent. Existing installed conversations and local API
settings must migrate intact. Siri and arbitrary on-phone XCTest compilation
remain outside this iteration.

The approved chat UI revision is implemented by Opus 5.5, with Codex responsible
for independent review and iPhone 12 mini validation. Its header has
only a list icon, a tappable title for renaming and a new-conversation icon.
Model controls show the concrete model name first; provider and API format are
secondary information in the picker. Existing recorded attributions remain intact.
Session actions and settings belong in the session list. Input uses an adaptive
one-to-six-line composer, removable image thumbnails and Photos, camera and
user-initiated paste. Replies use native block Markdown and attachment views. Real
model/tool phases must remain visible both in the chat and through the system
task surface while another app is foreground. The review proposes native SwiftUI
components over the existing AgentKit events. Attachment metadata extends the
current history with optional fields while retaining its current version;
image bytes remain outside portable synchronization. The earlier teardown fix
did not include this UI rewrite.

This revision must preserve every existing conversation/message ID, message
content, draft, selection and attribution. Back up the installed history before
upgrade, install using the same local bundle/signing identity, and compare the
original records after migration and device checks. User photos use protected
local binary files and explicit metadata in the existing atomic history; image
capability is checked against the accepted turn's frozen configuration. Failed
import/send retains the user's draft. Image-only sends and image steering use
AgentKit's existing image fields. Portable sync carries no image bytes or local
paths; attachment-unavailable placeholders and retention of unchanged local
attachments are part of compatibility validation.

The user explicitly removed multi-version history compatibility from this
unreleased iteration. Preserve the currently installed records through one
upgrade; do not build or maintain a general legacy-version compatibility layer
or expand the old-format test matrix. Existing portable merging remains a
current-data integrity requirement.

Normalize user images to a maximum 2048-pixel edge, apply orientation and remove
source EXIF/GPS before storage. A message may contain up to six images. Draft and
message references keep local files alive; accepted jobs freeze those references
alongside their model configuration. At request assembly, include at most four
prior user images and explain omitted or unavailable images in model context.
Text-only models require an explicit choice before dropping current input
images. Portable attachment metadata displays an unavailable placeholder on
devices without the bytes and participates in conflict identity without
changing identities for existing attachment-free messages.

Render headings, lists, quotes, fenced code and tables using native views.
Incomplete fences remain readable during streaming; code can be copied and
wide tables scroll horizontally. Links use an explicit URL-scheme policy.
Markdown remote images load only after a user tap, over credential-free HTTPS;
local image previews use the protected attachment files. Follow streaming output
only while the reader remains at the bottom, with an explicit return-to-bottom
control otherwise. Consecutive tool steps fold together without changing event
order or call/result pairing.

One reducer derives connecting, model response, phone action, retry, user-input,
cleanup and terminal status from actual events. The chat strip and system task
subtitle share it. Progress counts completed responses and phone actions rather
than a request budget. Queue rank is the position among waiting turns. Starting
a rejected system task must keep a recoverable unsent draft without overwriting
new edits; completed or interrupted phone work is never replayed automatically.

Android UI references add explicit queued and waiting-for-user states, compact
tool rows with step outcomes, and an outside-chat current-app/action indicator.
Keep Stop separate from the composer so running turns can still accept steering.
Use iOS's system task surface for outside-app status; Android application-overlay
windows are not an iOS implementation path. That surface is the system Live
Activity of BGContinuedProcessingTask; there is no custom ActivityKit/widget
extension or Dynamic Island design. A local appearance choice (system, light,
dark) is stored in UserDefaults and applied as the hosting window's interface
style, which every sheet presented in that window inherits.
Manual takeover is a proposal, not verified pause/resume support: continuation
requires a fresh observation and must not reuse stale nodes or replay past actions.
References are PalmClaw's session/attachment/tool UI, MobileClaw's inline action rows, MobileAgent-Android's
phase bubble and Doubao's official task-queue illustration.

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

Every turn that starts automation owns its runner PID. Retain the tunnel and
reopen the Instruments control channel for teardown because the launch channel
can close while XCTest continues. Once AgentKit has finished using tools, return to the
assistant through WDA, stop that owned process, then complete the background task
and release the serial queue. Ordinary chat starts no runner. Cancellation drains
the runtime's terminal events instead of abandoning an in-flight tool. Cleanup
runs without inherited cancellation; failures appear in the conversation status
without changing an already completed action into a replay.

Legacy endpoint/model and Keychain settings migrate once; production defaults
contain no private gateway or company identity. Local build overrides preserve
the installed test app identity without committing them. Device pairing import
and runner/VPN settings are local to each device.

## Proposed on-device workspace and scripting

Status: design under review, last checked 2026-10-10. The user's next capability
scope includes project directories, global/project AGENTS.md, skills, native
file and HTTP tools, and on-device scripts that can invoke phone operations.
Phone control remains central; scripts perform data processing and compose those
operations. Deferring scripts in favor of a phone-only reliability iteration
does not match this scope. Existing sessions, drafts and model choices must remain
intact. This section describes a proposal, not an implemented runtime.

Opus 5.5 and Fable 5.1 independently read the reference sources, exchanged their
analyses and reviewed the proposed integration. Their source-based lessons are:

| Reference and inspected revision | Mechanism to borrow | Boundary |
|---|---|---|
| [Operit](https://github.com/AAswordman/Operit/tree/dbf71916fae9750cfdc9f9a774f5a0fee56633fb) | Inject workspace rules and advertise skills through metadata before loading bodies | Its root rule reader is not a complete global/nested rule system |
| [Operit2](https://github.com/AAswordman/Operit2/tree/c539c203c91d7c14006b8d82f67f2a2bf1abcfa1) | Embed iSH and mount native workspace files into its Linux guest at the same path | Its timeout sends Ctrl-C without confirming exit; its current external-cwd bridge accepts container paths only |
| [Zafiro](https://github.com/niki914/zafiro/tree/6c7f7756d698f9ea02627e54e6e912317314fe9a) | Isolate Python execution, check worker health and coordinate cancellation | Android's dedicated app process is not a directly portable iOS process model |
| [Shelly](https://github.com/RYOITABASHI/Shelly/tree/b08b01b7a5d37db53a8afeb4a6bb73e0460bd1e1) | Package Bash, Node and Python as explicit runtime capabilities | Its Android linker/bionic executable path does not establish an iOS implementation |
| [Gemini Android](https://github.com/aciderix/gemini-android-app/tree/2c4d9bb085b0f026fbab1f52c60ddc9c447f7349) | Report when a selected document directory cannot become the shell cwd | A picker URI and a runtime path are not automatically the same workspace |
| [ClosePaw](https://github.com/imoonkey/closepaw/tree/75dae2653f5a6b25d5df51ee7008b0f830de1536) | Load app-specific skill instructions for the current foreground app | Cancelling an HTTP wait is not proof that a remote shell command stopped |
| [Kira/DroidClaw](https://github.com/levilyf/droidclaw/tree/5cc2bfd02d5bfb7f70d0404a5afc40369ccda262) | Bridge a script runtime to native phone actions | Its workspace creates AGENTS.md, but the inspected context builder does not load that file |
| [ZeroAI](https://github.com/Natfii/ZeroAI/tree/bbf422a7940bc6c5608685098b6ae28f48deadaa) | Generate tools from one capability-aware registry shared across agent entry points | Registration is not proof of runtime availability or callback behavior |
| [ClawMobile](https://github.com/ClawMobile/ClawMobile/tree/e15557122d95afbe3f91e2cd3300068760826f95) | Declare capability and platform limitations explicitly | Public material describes iOS app-local/shared-content scope; it does not expose a complete iOS phone-control implementation |

Keep native Swift and the pinned AgentKit as the sole agent loop. Validate iSH
first as a runtime candidate for Bash, Python and Node; do not migrate the whole
Operit2 agent framework. Native CPython embedding and NodeMobile are alternative
components, not evidence of a full Unix process environment on iOS. Runtime
performance, package compatibility and distribution requirements remain open.

Use an app-container project root shared by native filesystem tools and the
guest. Persist relative project identifiers, not an installation-specific
container path; freeze workspace selection when accepting a turn, alongside
the model configuration. Initially use native operations and explicit import/
export for external folders. Broader security-scoped/hostfs integration needs
its own validation. Preserve the existing portable chat synchronization; do not
automatically synchronize guest rootfs, caches, pairing records or credentials.
AgentKit scratch is bounded conversation staging, not an arbitrary project root.

Load app-global AGENTS.md, the project's root AGENTS.md and a skills catalog into
the actual model context, with skill bodies read on demand. Nested rule inheritance
is a later extension. A single ToolRegistry should produce tool descriptions,
authorization policies and capability prompt fragments. Native filesystem tools
need list/read/search/write/patch operations; native http_request needs method,
headers, body and structured responses beyond AgentKit's webpage Fetch tool.

Extract a shared PhoneExecutor from the current PhoneAgent/PhoneApproval path.
It owns action serialization, observation validation, effect authorization,
cancellation and WDA execution. AgentKit tools and script helpers must use that
entry point: directly invoking the current perform method bypasses the existing
approval broker. MainActor isolation alone does not serialize operations across
await. run_script waits asynchronously without holding a phone-action lock or
recursively entering AgentKit's single-tool scheduler. Script phone sub-actions
appear under that script's trace/progress; they must not create unpaired model
tool-result messages. Ordinary filesystem, computation and authorized network
operations need no per-step confirmation.

The first runtime probe must establish bidirectional workspace visibility, real
exit codes, separate stdout/stderr and bounded output with full output files.
Cancellation first revokes the script's bridge authorization, then interrupts
and, after a grace period, terminates remaining guest processes; inspect the
process tree before declaring completion. A timeout code, closed terminal or
cancelled HTTP request alone does not prove that execution stopped. Mount only
the project root. A token protects our bridge but does not protect WDA's raw
unauthenticated listener: test whether a guest can bypass the executor by calling
that listener, and establish isolation or authenticated access before claiming
the bridge enforces the action policy.

The proposed combined device task reads reminders, fetches HTTPS itinerary JSON,
uses Python to normalize dates and remove duplicates, writes a shared CSV, creates
the missing reminders through the phone bridge and reads back the result. Also
exercise cancellation, timeout, lost action results, duplicate submission and a
subsequent session. Unknown action outcomes require fresh observation, not replay.
Record cold start, memory and IPA size, then validate with USB disconnected on the
reference iPhone. No new runtime was built, installed or exercised for this source
review. Implementation assignment and schedule remain unassigned.

Only PocketAgent's iOS app/runtime and companion integration are affected by this
proposal. The Looktech Android app, firmware, schema, rpc and audio modules are
unaffected because this introduces no glasses-device contract or algorithm change.

## Delivery and rejected alternatives

Owner: Codex integrator and Opus 5.5 app developer.
Verify migrations, session isolation, provider selection capture, sync deletion
and concurrent history conflicts, build/install and actual model/tool execution.
IPA/source and repository scans precede GitHub push. Success-only evidence stays
in the parent workspace work/ directory. Synchronization runtime claims require
actual iCloud folder access; multi-device convergence requires two-device proof.

## Confirmed integration problems and fixes

With the phone in dark mode, choosing Light and then System in an open Settings
sheet left that sheet light, although the chat underneath and a cold launch
returned to dark. The chat root and the sheet each set SwiftUI's presentation
color-scheme preference, and clearing it did not reset the open sheet. The
choice is now applied once, as the window's override style; System clears it
to unspecified so the window and all its presentations take the system value.
A hidden, non-interactive probe applies only to its hosting window on attachment
and preference updates; changing appearance does not rebuild navigation state.

Device testing found message-container identifiers replacing the code-copy and
image controls' identifiers. Make message rows explicit accessibility containers,
and attach the transcript identifier to the scroll view before its overlay.
Switching from a tall phone-operation transcript to a shorter conversation also
produced an empty visible transcript while all messages remained in storage.
Key each transcript view by conversation ID so its scroll state is recreated for
the selected content. On the reference device, tall-to-short switching and
relaunch now retain visible messages; code-copy and image-preview controls remain
individually accessible, with copied code verified through the system paste action.

Image import initially combined Foundation's atomic and without-overwriting
write options, which traps instead of returning a catchable write error.
Use a fresh UUID path, reject an existing file and perform a protected atomic
write. Reserve image capacity before asynchronous Photos/paste reads; sending
waits for that session's selected images. Commit checks the six-image limit
again, and cancelled or orphaned imports release their reservations and files.

A rejected system task previously cleared the composer even though no model
run had started. Keep the original raw draft and a transient edit revision.
Restore it only before runStarted and only if the composer remains unedited.
Preserving new text while merging old images would attach an unintended picture
to the user's next message, so restoration is all-or-nothing. Failed prompts
remain in history; neither restoration nor cancellation replays actions.

Pending steering places the live assistant before a later user row, so observing
only the final row misses streaming changes. Track rendered text/reasoning and
tool growth across the transcript while retaining the reader's scroll position.
Remote Markdown images use a streaming byte limit instead of checking size only
after buffering the entire response. A session delegate validates redirects
before following and validates the final image response, because the local
network ATS allowance does not enforce HTTPS for every redirect.

Completed phone turns released only their tunnel connection. The WDA process
remained alive, and no activation request returned the assistant to the foreground.
Retaining the owned PID allows explicit runner shutdown after returning to the
app. The retained launch channel failed to stop the runner on the device; teardown
reopens that channel, checks the PID still belongs to the companion, and verifies
process disappearance. Native shutdown sends an acknowledged SIGKILL request
before releasing its service channel; fire-and-forget kill requests can be lost
on channel teardown. Failed HTTP/session setup resumes using the existing
owned connection so a retry cannot lose its first runner. Deleting only a WDA HTTP
session would leave XCTest alive.
Success, failure and cancellation use the same ordered finalization, and the next
queued turn cannot start before it finishes. The BackgroundTasks completion title
also changes from processing to the terminal result; iOS owns dismissal of its
system Live Activity.
Shutdown failures remain visible and are not retried automatically. A subsequent
runner launch uses KillExisting for its configured companion. The regression
check verifies both foreground return and process disappearance, rather than
treating a successful signal call or a closed HTTP session as shutdown proof.

The first CI privacy check matched the absolute checkout's `work` directory and
rejected every file on GitHub runners. Directory exclusions now inspect only
repository-relative paths. A temporary Git checkout under a runner-like path
verifies that clean source passes while a private child directory still fails.

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

- [PalmClaw Android UI](https://github.com/ModalityDance/PalmClaw)
- [MobileClaw Android UI](https://github.com/ChenKuanSun/MobileClaw)
- [MobileAgent-Android task status](https://github.com/GiggleWang/MobileAgent-Android)
- [Doubao phone assistant official UI demonstrations](https://o.doubao.com/)
- [AltStore Classic source schema](https://faq.altstore.io/developers/make-a-source)
- [EHPanda packaging workflow](https://github.com/EhPanda-Team/EhPanda/blob/main/.github/workflows/deploy.yml)
- [LiveContainer installation](https://livecontainer.github.io/docs/installation)
- [Apple directory access](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
- [Apple document version conflicts](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocumentBasedAppPGiOS/ResolveVersionConflicts/ResolveVersionConflicts.html)

Rejected alternatives: CloudKit/ubiquity containers require signing capabilities
that ordinary AltStore personal accounts cannot assume. A new generic database
or storage abstraction is unnecessary for this scope. Secret synchronization is
not part of portable conversation data.
