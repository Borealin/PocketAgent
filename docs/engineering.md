# PocketAgent engineering

## Requirements and scope

The [single-entry and long-term memory design](long-lived-assistant.md)
records the user-confirmed 2026-10-14 direction, the public research behind it
and the implemented P1–P4 contract: a default "你的助理" entry on the existing
AgentKit loop and phone execution path, one MainActor-owned strictly decoded
assistant-v1 history with scope/dependency rows, explicit host-written memory,
validated summaries and one pending-next request. Startup permits and awaited
transcript commit barriers preserve the no-replay boundary; correction
refreshes the next request; explicit forgetting shows its known dependency
impact before excluding sources. Status and verification scope are in
"Long-lived assistant (assistant-v1)" below. The user authorized a clean
breaking data format without legacy compatibility or migration, and then the
full implementation.

Native provider management on a dedicated page, provider/model selection per
conversation (the primary line and independent tasks alike), iCloud Drive
synchronization of portable data, reproducible IPA
builds and AltStore Classic/SideStore source publication. Borealin/PocketAgent is
public following the user's authorization on 2026-10-11. The assistant
release uses an empty assistant-v1 namespace with mandatory current-schema
fields. Old history and provider settings are not automatically adopted; new
provider IDs use current Keychain references without legacy-ID migration. Siri
and arbitrary on-phone XCTest compilation remain outside this iteration.

Setup must use one Base URL for standard model services, with Sub2API and protocol
presets, clear model-loading outcomes and manual fallback. iCloud setup proposes
a default PocketAgent folder, creates it after the first system folder grant,
restores the saved location automatically and allows an explicit replacement.
Pairing has a dedicated guide and format checks; script availability reflects
actual initialization and interpreter startup instead of archive presence.

The approved 0.3.6 work exposes native installed-app discovery, exact-name
opening and (in 0.3.6) a separate Spotlight search tool, removed in 0.3.7. Bundle-based opening must
validate the real list instead of trying remembered identifiers. Ambiguous
names return candidates; missing names direct the agent to system search.
Following the user's clarification, system search uses ordinary phone tools; ordinary page search,
observed buttons and swipes are the primary workflow. An additive logical-point
swipe tool supports nested scrolling and iOS edge-back gestures. Foreground/node
changes return a fresh observation when possible without replaying clicks or
input. Existing sessions, credentials and per-device
configuration remain untouched. Release acceptance includes iPhone 15 Pro
Xianyu search, the stable default-endpoint hint, clean IPA inspection and
verification of the public AltStore source against the released assets.

The 0.3.7 follow-up addresses the confirmed system-app discovery failure and
shared phone-operation timeouts. The user removed the dedicated Spotlight tool:
system search uses ordinary observation, tap, swipe and text input. Installation Proxy `Any` lookup through the phone's
existing RSD tunnel replaces DVT's development application list. A read-only
15 Pro query confirmed that the former provides `com.apple.Preferences` with
the localized display name “设置”, while the old model-facing list omitted it.
The same query showed a hidden CarPlay Settings app with the identical name;
`SBAppTags: hidden`, extension definitions/paths, non-APPL packages and demoted
apps are excluded before name resolution. IDs still come from actual metadata,
not a remembered system-app allowlist. Lookups fail explicitly if the service
cannot supply the catalog. FFI results copy their fields before releasing both
owned plist nodes and the boxed pointer array with a matching deallocator.
Per-request WDA diagnostics record only method, endpoint shape, elapsed time
and error identity; session/element IDs, arguments and response bodies are
excluded. System Home/search observations skip the automatic status-area
preparation gesture, avoiding an extra XCTest event during system transitions.
The removed Spotlight implementation also misclassified the 15 Pro's observed
`spotlight-pill` (an Other container) as absent because it only accepted Button;
ordinary tap can use the actual observed container instead. A product-tool
suite on the 15 Pro verified localized Settings lookup, exact-name and verified-ID
opening, changed content after a real swipe, and system search entry/input using
generic tools. The test used real task-title changes and the installed SideStore
Automation companion; it did not replace the original assistant or mutate its
history. The latest original WeChat turn opened WeChat before subsequent tap
and observation timeouts and system expiration; a separate new read-only open
and observation passed. That does not isolate or resolve the old tap stall.
WDA's pinned synthesized-event implementation includes an unbounded completion
wait, but no request-level log existed in the original failing turn, so this is
a source-level risk, not a proven cause. Keep the 15/20-second client limits and
no-replay semantics; newly recorded route timings support the next reproduction.
Do not claim generic removal of WDA timeouts or repair of cellular-only startup.

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
components over the existing AgentKit events. Attachment metadata is a required
field of the assistant-v1 session record; image bytes remain outside portable
synchronization. The earlier teardown fix
did not include this UI rewrite.

The assistant release is an explicitly authorized breaking change. It supersedes
prior preserve-on-upgrade requirements: no historical decoder, field backfill,
legacy deduplication/import, upgrade backup or multi-version migration matrix.
Use an assistant-v1 local namespace and separate assistant-v1 portable cloud
folder/envelope; prior client formats are rejected rather than converted. Old
folders are not active data sources and are not automatically removed. New
current-format messages keep their IDs, order and call/result adjacency; crash
recovery and storage failure handling remain required.

User photos use protected local binary files and explicit metadata in the new
atomic history; image capability is checked against the accepted turn's frozen
configuration. Failed import/send retains the user's draft. Image-only sends and
image steering use AgentKit's existing image fields. Portable sync carries no
image bytes or local paths; missing attachments display an unavailable
placeholder. Current-format conflict merging and deletion tombstones remain data
integrity requirements.

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
cleanup and terminal status from actual events. The chat strip retains its
detailed status; the system task uses the reducer's current action as its title
with an empty subtitle. Progress counts completed responses and phone actions rather
than a request budget. Queue rank is the position among waiting turns. Starting
a rejected system task must keep a recoverable unsent draft without overwriting
new edits; completed or interrupted phone work is never replayed automatically.

Android UI references add explicit queued and waiting-for-user states, compact
tool rows with step outcomes, and an outside-chat current-app/action indicator.
Keep Stop separate from the composer so running turns can still accept steering.
Use iOS's system task surface for outside-app status; Android application-overlay
windows are not an iOS implementation path. That surface is the system Live
Activity of BGContinuedProcessingTask; there is no custom ActivityKit/widget
extension or Dynamic Island design. Title updates use a specific current action,
with short real-stage fallbacks after an action ends; generic assistant labels,
repeated app names and step counts remain out of the system surface. Progress
and task completion keep their real-work lifecycle. The empty subtitle was
accepted in the installed app's read-only phone turn; completion showed its short
terminal title and the new icon. The new icon is an opaque 1024-square indigo/violet pocket
and speech mark with a white spark, shared by the app catalog and source feed;
the obsolete drawing script that generated a black asset is removed.

An opt-in 15 Pro screenshot series showed the system task surface expanded
across the top navigation area throughout multiple observations. The matching
foreground-app trees did not include its system controls, so app membership,
`visible=true` and an unchanged frame alone cannot prove that a coordinate is
safe to tap. Shorter text cannot itself be claimed to solve that obstruction.
A read-only Settings reproduction showed its covered back button still reported
`hittable=true`; moving the active-app detection point to its center also failed
to distinguish the surface. Neither is an occlusion guarantee. Apple's inward
horizontal Dynamic Island gesture collapsed the system surface while task
progress remained active. The phone executor now prepares a compact task
surface before observation and pointer/input actions, in its existing serial
action queue, and rechecks cancellation, script lease and foreground app before
and after the gesture. It rereads the page after preparation; model screenshots
keep their original coordinates. This is restricted to the captured portrait
iPhone layout with a Dynamic Island-sized top safe inset and matching WDA screen
bounds; notch phones, landscape and unknown layouts do not receive a guessed
gesture. No fabricated progress or background-task cancellation is used. The
new binary completed a read-only phone turn using default runner resolution and
its normal cleanup on a notch phone. A separate Dynamic Island return test ran
the preparation sequence, but its model task had already ended before capture;
it verifies ordinary return and harmless status-area preparation, not active
overlay mitigation. The earlier expanded-surface collapse remains the visual
proof for the gesture. Automatic preparation in the SideStore-signed new binary
still requires validation on the Dynamic Island device. System expansion and a
human switching apps can still race an action; no atomic occlusion guarantee is
claimed.
A 0.3.6 SideStore run on the iPhone 15 Pro subsequently reported no visible
Dynamic Island status during operation. Its logs confirm task submission,
handler execution, continued real progress and normal completion, with no
system expiration. The same run issued repeated status-area preparation
gestures. Static inspection shows that `compactedTaskTitle` only controls a
short delay: the horizontal gesture is still issued on every normal observation
and node preparation even after previous preparation. The current
[iOS 27 user guide](https://support.apple.com/en-mide/guide/iphone/iph28f50d10d/ios)
defines collapsing an expanded activity as an upward swipe; the existing
horizontal recipe therefore cannot be treated as a verified cross-version
collapse-only operation. An active-run device follow-up does not establish horizontal preparation as
the cause of the missing indicator. An isolated host on the same 15 Pro showed
no system task indicator in its own foreground UI, but an expanded task card
appeared after switching to Settings. Two HID gestures matching the product's
horizontal coordinates initially left the expanded card visible; the later
compact capture coincided with an unrelated notification, so that transition
cannot be attributed to the gesture alone. Another matching gesture on the
visible compact indicator did not hide it. A fresh task with no horizontal
preparation provided a clean upward-swipe control: the expanded card collapsed
to its icon and progress ring while the same task remained active. This is a
manual HID result, not acceptance of a new automatic WDA gesture.

A real turn in the existing SideStore 0.3.6 app also showed an expanded task card
outside the app, followed by a compact icon/progress ring during operation. It
did not reproduce complete loss of the indicator. Its read-only Settings goal
was not completed: Chinese-name lookup found no exact Settings entry, English
lookup returned extension names, Spotlight and a subsequent swipe timed out,
and the system expiration handler then terminated the task. A separate follow-up
finished without opening Settings; the model chose another inventory lookup
and declined the requested known system ID. These are app-discovery/model-flow
and automation-timeout observations, not evidence of a Live Activity failure.
The old conversations, messages, drafts and model selections were compared
before and after and retained. No product gesture change or new IPA is claimed.
The original missing-status report remains unexplained outside the observed
foreground/background distinction. Compact-status preservation under repeated
WDA preparation, safe detection of expanded surfaces and reliable automatic
collapse remain open requirements; successful request logs do not prove them.

A local appearance choice (system, light,
dark) is stored in UserDefaults and applied as the hosting window's interface
style, which every sheet presented in that window inherits.
Manual takeover is a proposal, not verified pause/resume support: continuation
requires a fresh observation and must not reuse stale nodes or replay past actions.
References are PalmClaw's session/attachment/tool UI, MobileClaw's inline action rows, MobileAgent-Android's
phase bubble and Doubao's official task-queue illustration.

## Decisions

Pin AgentKit to the published fork Borealin/AgentKit at
22fc575009bde3a2097ac1a49908ffa239b9c029 (upstream 8108c9b plus the bounded
`consume` API used for context maintenance) and keep the verified
native idevice/WDA execution path. Use a small Codable store with Keychain
credentials, per-session selection and frozen queued-turn configuration.

Use a folder selected via the system document picker for iCloud Drive. On first
setup, create a PocketAgent child in the granted location; explicit replacement
and existing bookmarks continue to use their exact folder. An arbitrary iCloud
Drive folder cannot be silently accessed before the picker grants permission.
Avoid an
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

The user chose to make Borealin/PocketAgent directly public on 2026-10-11.
Use its existing main-branch feed and GitHub release assets; no separate release
mirror is needed. The README provides the official HTTPS AltStore source deep
link, a source URL for SideStore, manual IPA downloads and initial device setup.
The feed, icon, both IPAs, checksums and complete corresponding source are
publicly accessible without GitHub authentication. Public hosting does not
remove sideload signing, the separate automation companion or device setup.

## Architecture and compatibility

App: SwiftUI assistant entry, task/history list, memory panel, provider/sync views. AgentKit: model protocols and agent
loop. Native: Rust FFI RP/DDI preparation, then owned DDI service primitives or selectable WDA runner/HTTP tools.
Run configuration (provider, model, key, local context budget, project,
backend, clipboard policy, attachments) is captured at acceptance; changing a
selection does not alter accepted work. `HistoryOwner` is the only writer of
`assistant-v1/history.json`; run events are recorded in event order with their
root membership, tool result IDs are preserved, and model requests and tool
dispatches wait for the saved request view of their inputs. Restart interrupts
active work and asks before any pending request continues; nothing is replayed.

Every turn that starts automation owns its runner PID. Retain the tunnel and
reopen the Instruments control channel for teardown because the launch channel
can close while XCTest continues. Once AgentKit has finished using tools, return to the
assistant through WDA, stop that owned process, then complete the background task
and release the serial queue. Ordinary chat starts no runner. Cancellation drains
the runtime's terminal events instead of abandoning an in-flight tool. Cleanup
runs without inherited cancellation; failures appear in the conversation status
without changing an already completed action into a replay.

Current-format provider configuration is set up directly; no legacy endpoint,
model or Keychain-ID migration is required for the assistant release. Production
defaults contain no private gateway or company identity. Local build overrides
preserve the installed test app identity without committing them. Device pairing import
and runner/VPN settings are local to each device.

## Long-lived assistant (assistant-v1)

Status: P1–P4 implemented on `codex/long-lived-assistant-implementation`;
Core tests and the iOS Release build/IPA inspection pass; device acceptance
is partial (see below). Design and file map: [long-lived-assistant.md](long-lived-assistant.md).

- Data: one strict `assistant-v1/history.json` (explicit nulls, no legacy
  decoder), `assistant-v1/providers.json` with local per-model context budgets,
  `assistant-v1/Attachments`, and an `assistant-v1/` subfolder in the sync
  location with a generation-tagged portable envelope. Earlier files and folders
  are never read, converted or removed. An unreadable current file blocks
  writes until an explicit reset moves it aside.
- Owner: transactions publish only after a successful write; run events stay
  visible when their write fails, storage becomes dirty, every gate fails and
  only an explicit retry restores storage (never the stopped run). The writer
  re-encodes only changed messages and splices them at a unique per-write
  sentinel.
- Gates: a startup permit is committed before `runtime.start`; each model
  request waits for the saved request view (text/modelText, calls, provider
  items, image identity) of every real message since its prompt; each tool
  dispatch waits for its assistant call and per-call result watermarks of earlier
  calls (local result saved or provider-answered). One turn deadline; effects
  require the job to still own its session and run.
- Context: same-scope complete segments, deterministic interruption repairs,
  summaries accepted only when coverage, digests and parent chain recompute
  (CAS commit), fresh memory block per request, forget filtering, stale phone
  screens projected, one estimator with bounded per-model usage calibration;
  known windows/explicit ceilings are hard guards, unknown windows only a soft
  target.
- Memory: host-exact writes (panel, chat chip, `记住：`/`/remember`), model
  read-only (`memory_search`/`session_search` through AgentKit's protocol),
  correction by ID/revision CAS, forgetting through a recomputed preview over
  the known read graph (iterative, linear).
- Pending: one detached → promoted request with fair ordinals, Stop epoch,
  held/needsResume states, explicit same-ID continuation only before the permit,
  abandon-unstarted, sync deferral and attachment retention.

Verification scope (2026-10-14): Core suite (247 tests) passes on the Mac host,
including the commit gates through the pinned AgentRuntime, crash points of the
pending state machine and 12k-root dependency chains. Release build and IPA
inspection pass. On the iPhone 12 mini the dev build installed over the existing
identity and its first launch created the empty primary line once while the
earlier-format files stayed unchanged; further device scenarios were paused
because another session was operating that phone. Scenarios that need a model
(recall after model change, Chinese search through tools, correction/forget in
model context, fresh observation without replay) need a provider configured in
the new namespace on the device and are not yet verified. Long-history numbers
are host measurements: per-event write p95 0.05 s at 10k messages and 0.2 s at
50k (110 MB file), transcript paging renders 400 messages per page.

AgentKit dependency: the bounded maintenance API
(`AgentProviderClient.consume(_:limits:onEvent:)`: 16 MiB transport, 256 KiB
SSE line, 65,536 events, terminal required, callback in the producer task) is
published on the fork branch `codex/pocketagent-bounded-consume` and pinned at
its immutable revision; default stream/complete and the loop are unchanged.
Summary folds stream through it into the Core collector under one 150-second
maintenance deadline shared by up to three folds and capped by the turn
deadline, a 45-second idle limit refreshed only by new real content, coalesced
real progress and cancellation propagated as cancellation. A system expiry
during maintenance ends the turn before its permit (draft returned or pending
request held, nothing dispatched); progress reflects only real increments, so a
provider that stays silent for about 30 seconds can still be expired by iOS. Host integration
tests drive the real `consume` through a URL protocol stub; device-side
summarization has not run yet.

Confirmed problems found during implementation review and fixed:

- The incremental writer located the messages array by the first
  `"messages":[]` in a session's bytes. A session whose attachments map had a
  key named `messages` produced, depending on JSONEncoder's per-process key
  order, a file that decoded with `keyNotFound` (reproduced in 10 of 20
  processes). Splicing now uses a per-write sentinel pair that must occur
  exactly once (else a full re-encode); regressions cover nested same-named
  keys, conflict copies and a nested-key-first byte layout.
- A later event written successfully after a failed write cleared the dirty
  state by itself. Only an explicit flush clears it now; failed epochs stay failed.
- Pruning removed roots whose source history was deleted even when another root
  still read them, losing transitive forget edges. Such roots now keep identity
  and edges (unverified); decoding validates edges and rejects cycles.
- Per-request memory relevance used the last user message, which on phone turns
  is the appended screenshot caption. It now uses the latest recorded real user
  message.
- Portable messages and sessions still omitted nullable keys (tool call ID/name,
  model text, attribution, selection, conflict parent) and defaulted missing
  attachments, preserving pre-assistant-v1 canonical bytes. They are now strict:
  explicit nulls, required keys, attachments always present; canonical bytes and
  the derived conflict-copy IDs are pinned (independently recomputed).
- Repeated, alternating or empty summary snapshots counted as maintenance
  progress and refreshed the idle timer; only new non-empty content counts now,
  deduplicated across the whole response rather than a recent window.

## Device Hub backend feasibility

The separate [Device Hub design](devicehub-control.md) remains production work in
progress. A local native probe on the user-selected iPhone 12 mini reused the pinned
idevice revision and current RP tunnel patch without replacing the installed app.
It disproved the mandatory-display-stream assumption for ordinary touch on iOS
27.0 / 24A437 with mounted DDI 27A5252f / CoreDevice 642.15. On-phone screenshot,
Calculator launch, visible `7 + 5 = 12`, Home return, ASCII key delivery and raw AX
requests 6 → 1 → 5 were exercised without XCTest/WDA. This is feasibility evidence,
not a delivered PocketAgent backend: full AX/tool mapping, native system dialogs,
Unicode paste and interrupted/background lifecycle were not covered by that
initial probe. Production integration is described below; unplugged operation and
other DDI/OS combinations remain open. The public release still uses WDA, while
this branch follows the user-selected DDI default with a manual WDA selector.

## Setup and readiness

Status: implemented and archived. The same-identity update retained the current
history and device configuration. On-device settings confirmed automatic script
readiness, retained synchronization and a successful RP/VPN check. Default-folder
creation still needs the first system grant on a fresh setup; an existing
bookmark is intentionally retained. Provider records
retain their current schema, IDs, exact inference/catalog addresses, Keychain
bindings and conversation selections. Standard presets derive inference and
model-list paths from one Base URL; custom routes keep full addresses. Catalog
loads are explicit, show progress and failure/manual fallback, and discard
responses after connection edits. Refresh preserves manually configured models
and image support. Explicitly changing a custom connection to a preset can
reuse its precisely reversible inference address, including when its catalog
was disabled; simply opening it does not alter either stored address.
Sub2API protocol must match the API-key group; its ordinary
routes use /v1 and specialized Antigravity routes retain their explicit prefix.
The route reference is [Sub2API gateway.go at 3a6fd1c](https://github.com/Wei-Shaw/sub2api/blob/3a6fd1c9db07203ca308aaba69e502bc1f35b307/backend/internal/server/routes/gateway.go).

The default sync flow creates only the named child after folder authorization,
using coordinated access and a protected, backup-excluded bookmark. Existing
folder grants and sync files are retained. The picker remains necessary on a
new installation; no entitlement or hardcoded iCloud filesystem path is added.
Phone setup distinguishes RP pairing records from SideStore/USB Lockdown files,
limits import size and retains the native parser validation. A temporary tunnel
handshake checks pairing and VPN without starting an automation runner. That
result does not establish Automation installation or XCTest authorization.

The Mac onboarding guide uses upstream idevice_pair v1.1.0's universal GUI and
documents the released 0.3.1 and staged 0.3.2 import locations. An optional Bash
download helper pins its official DMG URL and SHA-256, uses an independently
created private Downloads directory, verifies before opening and never reads or
writes a pairing record. It does not install the GUI or change the phone. The
tagged GUI prepares DDI and enables wireless debugging on USB selection; this
is stated in the guide. RP export is structurally compatible; RP validation is
independent of Automation/XCTest authorization. The command-line alternative uses a unique host
name because idevice derives the RP peer identifier from that name; regenerating
with a reused name can replace the key behind an existing peer identity.

The GUI's Create step triggered a separate RP Trust prompt on a phone whose
USB connection was already trusted. Its status remained "Trust this computer
on your device" until that phone-side step was completed. The guide now
distinguishes initial USB trust from the new RP identity's trust/passcode
prompt; entering the passcode stays a physical user action. Keep that stage
pending until the device's system prompt actually completes.

A SideStore-signed 0.3.1 installation returned `idevice 13/0:
UnexpectedResponse` for every phone tool. Opt-in stage logs then established
that RP connection and DDI preparation succeeded, but DVT runner launch failed.
The main app's embedded runner ID was unsuffixed while the installed companion
had SideStore's signing suffix, with no local override. Configuring that exact
installed ID made runner launch, WDA readiness, screen observations and runner
shutdown succeed. This isolates the startup failure to the runner ID mismatch;
it does not establish that every later VPN or model request will succeed.
Tool errors remain transcript results: a completed model run can contain failed
phone tools. Native file logging is initialized at app launch, so enabling it
requires saving settings and relaunching; it stays at Info level without debug
key dumps.

Separate phone-tool failures returned `idevice 16/0: InternalError("connect:
Socket(...ConnectionRefused...)")`. The native call emits this error at the
initial TCP connection to the configured local VPN RemotePairing endpoint,
before pairing verification, RSD, DDI or runner launch. These runs had no
`rp_tunnel_connected` or `wda_ready` event, so they are not failures of WDA's
HTTP listener or of the corrected runner ID. A controlled iPhone 15 Pro test on iOS 27.0.1 with LocalDevVPN 1.3.0
confirmed the trigger: cellular enabled with Wi-Fi unassociated refuses both
initial RP and Lockdown TCP connections; disabling cellular makes both succeed.
Header-only USB capture shows the SYN traversing the utun interface, the VPN
swapping source/destination and reinjecting it, and the local TCP stack returning
RST while cellular is enabled. It is not a connection sent directly to the
carrier or a dependency on the computer's LAN. Binding the client to utun or its
source address, changing the tunnel interface to a /30 subnet, and disabling
TCP ECN did not recover startup. The original /32 VPN configuration is retained.
The precise iOS listener/interface admission rule remains unresolved; current
XNU source permits receive-interface restrictions to exclude a listener and
produce a closed-port RST, but that is a hypothesis without effective listener
policy evidence on this device. Do not replace a usable pairing record or
change wireless flags speculatively.

On the same iPhone, the user set LocalDevVPN's wireless-data permission to
WLAN only while leaving global cellular enabled. The observed state was 5G,
Wi-Fi unassociated and VPN enabled. Three fresh PocketAgent 0.3.5 connection
checks at 14:37 on 2026-10-12 failed at initial TCP with `connection_refused`
(idevice 16/0); the checks did not consume a prepared tunnel. This permission
change did not recover startup in the existing VPN session. No additional
permission-denial error was observed, so it does not prove a new permission
block or the exact receive-policy cause. A VPN restart under this permission
was not tested. Conversation records were retained.

A separately built and installed diagnostic app established a real RP/CDTunnel
with cellular off, retained its actual handles and process, then restored 5G.
Over that retained tunnel it successfully queried DDI/DVT, started Automation,
read WDA status and the Settings hierarchy, returned to the diagnostic app and
stopped its owned runner. These operations used phone-side idevice and local
HTTP without a computer port forward. USB remained connected for control and
header-only evidence collection, so physical disconnection acceptance remains
separate. In the attempted physical disconnection test, the preparation lease
had expired before USB was removed; the first attempt rejected that expired
lease, and later attempts opened new cellular TCP connections and were refused.
That result does not test survival of a live retained tunnel after USB removal.
The 120-second window is too short for unattended device acceptance. Independent
Claude Opus 5 review, checked against the source by the integrator, recommends
foreground retention across turns with a read-only liveness check before reuse,
stopping each turn's owned runner, and explicit re-preparation after transport
failure. A Shortcuts-assisted bootstrap must finish both initial RP control and
dynamic TLS/CDTunnel connections while cellular is off, restore data on failure,
and start model requests/DDI downloads only after data is restored. These are
follow-up design recommendations; the 0.3.5 candidate retains the implemented
120-second preparation behavior. No background lifetime is guaranteed.
The successful wired sequence remains a recovery
proof, not direct cellular-only bootstrap or a proven change to Apple's
listener policy.

Review boundary: the public XNU interface definitions include delegated
cellular/expensive properties, but no actual iOS 27 listener flags or NECP state
were read. NWPath metadata cannot establish those private fields. The review's
claim that `LOCAL_RUNTIME.block_on` stops networking between calls is not
supported: the pinned FFI uses a multi-thread Tokio runtime. The user subsequently
reported that restarting LocalDevVPN with cellular off and then restoring
cellular, in multiple orders, did not recover access, and that direct loopback
RP access also failed. These are user-reported negative results; an
endpoint-specific loopback trace was not captured independently. The WLAN-only
permission test above did not recover startup either. No tested configuration
has recovered initial cellular-only connections.

The whole-path follow-up with Claude Opus 5 examined public PocketAgent and
LocalDevVPN source. The integrator independently checked its claims: the
refused configured RP socket is distinct from the later negotiated TCP socket
and TLS/CDTunnel handshake. `NWPath.isExpensive` can describe an expensive path
but cannot prove private `if_delegated` or effective listener/NECP state. The
combined 10.7.0.2/30 probe was already negative; 10.7.0.2/24 was not isolated.
Changing similar addresses again is not an evidence-based fix. A self-owned
wildcard listener plus exact packet-path capture is the next narrow
discriminator: success would prove that tested app-owned flow reaches its
listener, not prove daemon policy or that the problem is unfixable. That probe
has not yet been executed. Existing retention evidence supports a transport
lifecycle workaround; it does not establish a VPN-only configuration fix.

The advanced endpoint field previously described its saved effective value as
the empty-field default. Saving a loopback override therefore changed the
"leave empty" hint to that override, although clearing it still selected the
embedded/default VPN address. The hint now reads the embedded fallback directly;
the effective address still uses the saved override first. This changes no
stored settings, pairing records or conversation data.
The override/default distinction is now accepted in the real 15 Pro settings
view: the saved override remains in the text field while the hint shows the
embedded default. Only the independent test app's setting was changed and
restored; the original SideStore app's preferences are unchanged. The fix ships
with the 0.3.6 candidate.

The App recovery implementation is pending device acceptance. Model owns a
short-lived prepared RP connection shared with its next phone action; ordinary
connection checks still release their temporary tunnel. Settings instructs the
user to disable cellular, disconnect Wi-Fi, keep LocalDevVPN connected, prepare
the connection, restore cellular, then send a new request. Preparation starts
no WDA or phone actions. A 120-second lease and the system's shorter background
allowance limit retention. First phone use consumes the real handles and runs
normal DDI/runner/WDA verification; completion releases that turn's resources.
Pure chat/file/network turns retain an unconsumed connection until its deadline.
Expiry, Stop, explicit release and device configuration changes invalidate it.
An expired handle is never reused; tool attempts rejected for expiry stay
rejected in the same turn, while an explicit new turn or successful ordinary
connection check clears stale recovery state. No phone action is replayed.
Settings handshakes, configuration changes, startup and cleanup share a serial
connection gate. Diagnostics record default path flags and TCP/RP failure stage
in a protected, backup-excluded connection log with setup/active-turn context;
they omit device identifiers, addresses, credentials and message content. An
unsatisfied default path is not treated as proof that the local VPN is down.

[SideStore's cellular refresh manager](https://github.com/SideStore/SideStore/blob/0dd743f75afc358b0ba4a002feb5f19474492371/SideStore/Core/Shortcuts/CellularRefreshManager.swift)
uses configured Shortcuts to temporarily disable data and restore it around
device work. [Roam Control's guide](https://github.com/seanhowarthdev/Roam-Control/blob/456049eff7c9acb0b041db086e840915b283f4a8/Documentation/UserGuide.md)
documents restoring data after a secure session is established. These inform
the guided recovery, but automatic Shortcuts configuration is not implemented.
Only PocketAgent's iOS connection lifecycle is affected; Android, glasses
firmware, schema and RPC contracts are unchanged by this local developer tunnel.

The default now resolves the exact installed companion using the current
main app's single signing suffix in the known public bundle-ID family. A manual
override wins; local build IDs remain exact. It never selects another account's
runner by name or arbitrary prefix, and missing matches explain how to install
Automation or correct the advanced override. Installed IDs are copied from DVT's
application listing and not persisted or logged. The short-lived listing client
releases its borrowed server before ProcessControl is constructed. A dedicated
native deallocator releases both plist nodes and the owning boxed slice; the
upstream general array helper omitted its outer buffer. DVT connect, installed
application listing, ID resolution and launch each log a start/failure stage
without personal identifiers. Device configuration and conversation storage are
unchanged.

The app automatically imports/boots the bundled Linux environment and runs
Bash, Python and Node startup checks. These read-only checks share the existing
script queue, mount no project and expose no phone bridge. Readiness changes
publish from real preparation/check outcomes; kernel or process-cleanup failures
show a relaunch requirement instead of a ready state. Workspace/rules controls
remain separate from the dedicated script environment status.

The startup check is one shared owned task. Closing a SwiftUI settings task
must not cancel its polling sleeps: swallowing cancellation previously caused
a busy loop. The detached check retains ownership of preparation, polling and
cleanup, and callers only await its result; reopening settings cannot start a
second check.

During the connected update, an installation request stalled while the
assistant was running. Stopping only the assistant process and retrying the
same-identity IPA completed the installation without deleting its container.
The cause of the service stall is not established; avoid treating a timeout as
a completed install, and verify the installed version before retrying. The
Automation process separately exited when its system passcode authorization
timed out. Its log established an authorization timeout; later bundle loading
and UI automation still need validation.

The existing confinement stress test initially failed in CI with zero reads:
its rename/unlink gap allowed a normal write to create a new parent, leaving
the original read fixture parked elsewhere. The test now atomically exchanges
the directory and outside symlink, keeping both entries present. It retains
concurrent successful-read and no-escape assertions, adds actual-swap/error
witnesses and checks the normal read before and after the attack. Production
file confinement is unchanged.

## DDI phone backend (2026-10-12)

Status: implemented on the devicehub-control branch; selected-device acceptance
includes the shared executor and production chat path for clipboard-based cross-app Unicode input.
The same-identity original-app update preserved existing data, and the settings
selector was exercised in both directions before restoring DDI.
The user selected DDI as the default with a manual
WDA selector, and requires text input in other apps without XCTest. The DDI
path and all new input methods must also avoid testmanagerd/XCTestSession and
UI Automation authorization; removing the separate Runner alone is insufficient.
The attempted local NSXPC Unicode integration has been withdrawn because it
violates that requirement. Clipboard-free Unicode with normal business callbacks
remains unresolved under this constraint. On 2026-10-22 the user accepted the
existing paste, physical-key and guarded AX replacement routes and deferred the
new Unicode route; it is no longer an input-delivery prerequisite. The APIs
already exist, so this decision needs no new runtime implementation. See the
[consolidated findings and review](devicehub-control.md#input-decision-and-review-disposition-2026-10-22)
for the three-method contract, fixed review issues and remaining stability limits.
Existing explicit WDA compatibility is separate and never an automatic DDI fallback.
The subsequent strict-no-XCTest investigation closes the ordinary-app IOKit
type-zero lead on the inspected iOS 27.0/24A437 seed: connection creation requires
HID admin permission; nonzero types require HID event-dispatch permission at the
virtual-service/dispatch receivers. An ordinary-signed, UUID-pinned admission
probe creates a type-zero client object but obtains no server port, while types
3/4 obtain valid send rights. No input event is sent by that probe; the dispatch
restriction is established from matching receiver code, not a runtime dispatch
result. This does not establish that an Apple DDI sender has the same restriction.

Independent UITextView controls receive a physical HID `7`, update the business
model and call `textViewDidChange`, both with and without an active media session.
Arbitrary Unicode remains unproven. Raw DDI `createService` requests using either
a Unicode-page or standard keyboard descriptor trigger the same dtuhidd
RemoteXPC reply-channel assertion; event-channel framing instead times out without
an observed service. Matching receiver disassembly places the assertion in the
CreatedServiceID encoding/sendReply path, without proving the reply-object
root cause or service lifetime. No Unicode input report is issued. Establish the
legitimate creation/reply protocol and text receiver before any future integration; neither
request acceptance nor a HID Unicode usage page proves committed text. These are
research boundaries, not a new product input method or stability acceptance.
The baseline is main `f8f82a4` and all 14 phone tools retain their schemas,
snapshot validation, script lease checks, FIFO action queue and no-replay rule.
The backend is captured in ChatJob at enqueue, alongside the model configuration.

PhoneControl supplies observations and primitive effects to the existing executor.
DDI reuses RP/DDI preparation, gets launchable installed apps through the same Installation Proxy metadata
filter as WDA; AppService streaming supplies native process-path matching, reads bounded AXChildren graphs and takes native screenshots.
Foreground identity comes from a bounded read-only hit scan and a unique
process/app-path match. A blank centre point returned AX error 8 while the same
app's visible input-field point returned its complete tree; the selected point is
reused and checked again after graph traversal. Unknown process paths still fail.
Only verified portrait primary-display geometry is accepted; unsupported or
unidentified surfaces fail before coordinate input. WDA still owns its runner PID
and HTTP session, and is never selected automatically after an uncertain action.

Native source lives in Native/ddi and bootstrap copies it into the pinned idevice
FFI checkout keyed by upstream revision and the patch digest. Upgrades create a
new managed checkout instead of reapplying a new patch to the old patched tree;
unknown edits are refused and preserved. Corresponding-source packaging resolves
that same checkout for upstream sources and crate vendoring. AX keyed archives remain data, with size, depth, cycle, reference
expansion and message limits. One semantic request is outstanding at a time; a
failed AX socket is closed before fresh read-only recovery. Cancellation has a
separate atomic handle. Touch/button releases and empty key reports precede queue
release; the turn owns its virtual keyboard until cancellation or finalization,
then confirms its removal. No media stream is opened. Finalization returns to the
assistant and closes owned DDI services before releasing the tunnel.

Native calls now return effect-phase metadata through FFI. Pre-effect refusals
remain eligible for read-only recovery and a separately planned action; an uncertain
effect or failed input release still disables input and explicitly requires a new
turn. Composite Swift tools retain any earlier clipboard, focus or clear effect in
their outcome. No branch replays input or switches routes. The shared installed-app
catalog is loaded before native DDI readiness is published, so a failed inventory
read can resume instead of turning a live session into an empty-catalog result.

Optional type_text method=null follows the existing omitted-method paste default
and frozen policy on both backends. Nonempty paste cannot be confirmed from a
placeholder-equal AX value. Gemini receives a wire-only OpenAPI schema projection
without additionalProperties or uniqueItems; AgentKit's registered runtime schema
and the executor's sequence, duplicate-modifier and clipboard validation remain
unchanged. The other provider schemas retain their original declarations.

Confirmed integration fixes: decoding AX UID zero as an empty string changed the
translation token's null fields and the device refused its attributes request.
Null references now remain null and a regression covers that wire shape. The
initial all-app inventory setup timed out; the streaming inventory completed
initialization on the same device. Background UIKit writes left the old clipboard
value in Spotlight; foreground preparation was a temporary workaround. That
workaround has been removed because it required target restoration and excluded
system processes. The native backend now sends CoreDevice SET to general with
UTF-8 text UTIs, reads exact bytes back before clearing, and uses a fresh read-only
connection to confirm them immediately before HID paste. It does not activate the
assistant. Existing foreground/node/geometry checks still govern every input.

The earlier raw probe logged plist Data as JSON null and recorded timeouts
alongside SET/PULL replies. These observations did not establish failed storage;
reading UIPasteboard in the app was also not an independent cross-app insertion
witness. Apple-client request tracing confirmed the general/item/text-UTI shape;
the current idevice SET and Apple client both read test UTF-8 back on the selected
phone through the Mac transport. The on-phone RP path has also delivered Unicode
to independent UIKit fields and Spotlight without activating the assistant.
The prior receive-timeout root cause remains open. No success claim follows from
an ACK alone. Initial keyboard commands left partial
old text until a keyboard-settle interval and individual key-up reports were added.
For a focused editable TextView with omitted text attributes, a nonempty
replacement defers clear confirmation to the exact post-paste value; omission is
not treated as proof of emptiness. Clear-only still reports unreadable values.
Replacement input returns
an unconfirmed result if its fresh AX value does not match. Missing value and
placeholder cannot confirm empty input. Secure/insert-without-clear results
explicitly report input_verified=false and action_outcome=submitted; they do not
claim exact content confirmation. Secure text subrole 5
is normalized and its value is excluded from tool results.
The full executor check also exposed fragmented DTX replies: fragment zero is a
header-only envelope whose nonzero length describes the message, not following
bytes. The reader now follows that framing and a duplex-stream regression covers
it. AX setup failure attempts unsubscribe before dropping the socket; failed
input cleanup closes AX and disables further input while preserving owned release
state for finalization. AppService activation uses terminateExisting=false; returning to a running
assistant must preserve the process that owns the turn and its finalization.

Device acceptance exercised all baseline tools through the shared executor against independent
UIKit fields and ordinary system search, with actual editing callbacks and no
assistant activation during background typing. Normal and multiline replacement
were confirmed by exact fresh AX values; the known secure test text was witnessed
by the independent receiver while the tool result remained redacted and unverified.
Stale snapshots refused input, in-flight long-press cancellation released the owned
contact, and finalization removed the keyboard without cleanup warnings.
New test-app network permission
prompts interrupted initial runs before target input; those runs are unconfirmed,
not passed. The production chat path also confirmed exact ordinary-field replacement
in the independent receiver and returned to the existing assistant process.
The original App's first host-prepared prompt paste requested iOS paste permission;
the bench setup allowed that known prompt before starting the production turn.
This is global paste-based input, not proof of acceptance by every custom control.
The HID API carries keyboard usages. type_text now accepts optional method=ax
for nonempty clear=true replacement of ordinary TextField/SearchField nodes;
omitted method retains paste, and WDA rejects explicit AX before preparation.
AX uses request8/attribute53 once after fresh native identity/foreground/frame/hit
checks, without focus, clipboard or HID effects. Model and script calls share
TextInputRequest validation, including the frozen clipboard policy. A fresh
exact non-placeholder AX value is field confirmation, never business validation;
results label its source and require observing target App behavior. Observations expose known focused
state and the AX result reports target_focused without inferring it from the setter
acknowledgement. The model
confirms focus or uses node-bound press_keys before submission. Callback and
empty-value compatibility limits, and completed selected-device acceptance, are recorded in
[devicehub-control.md](devicehub-control.md#ax-final-text-route). Real search also exposed a fractional-frame
round-trip counterexample that can falsely trip AX's strict frame check, and a
unreadable App Store/Safari foreground after submission. These are recorded as
compatibility/observation limits; submitted errors require a fresh read, never replay.
A later Mac-side UniversalHID bench check confirmed
ASCII with an English layout and Chinese via existing Pinyin candidates plus
Space, with exact AX and independent UIKit callback confirmation and no clipboard
access. This is input-method feasibility, not an integrated on-phone input mode.
The IME's marked Latin value differs from committed text; a future implementation
must verify layout, candidate and final content. Candidate paging, rare/polyphonic
characters, mixed text, emoji and interrupted composition remain unverified.
The user approved the additive input contract on 2026-10-13. type_text keeps its
final-text schema; press_keys supplies 1–32 physical key positions and modifiers
on a freshly observed input field, using the owned DDI keyboard and fixed timing.
It returns the actual screen with input_verified=false and unknown composition/
layout, rather than claiming a committed Unicode string. Already-focused fields
are not retapped. WDA does not expose this new DDI primitive.
The device-local clipboard policy defaults to allowed for compatibility, is frozen
at job enqueue, informs model tools and is enforced in the shared executor for
scripts and model calls before effects. Disallowed copy/cut/paste chords are also
checked at native input validation. No route switches or replay follow uncertain
effects. This extension is implemented and the selected-device gate is complete; design
and recovery limits are in devicehub-control.md.

The first production-chat keyboard run opened the target successfully but failed
at mainKeyboard creation with a transport error. Independent UIKit callbacks
confirmed no text was inserted; subsequent input in that turn was refused as
uncertain. The candidate now opens a fresh HID channel before its first owned
keyboard creation, after any touch is released, without retrying an effect.
This addresses reuse of the setup channel after model inference; idle transport
versus prior no-reply touch traffic is not yet isolated. The fresh-channel
candidate passed physical ASCII, Shift and digit input, and two-part Pinyin plus
selection of an actually observed candidate. The latter reported unconfirmed
final cleanup despite independently confirmed committed text. Keyboard lifecycle
requests now use their own fresh, retained HID channel; touch reports, including
candidate selection, keep the original channel. Static cleanup-phase diagnostics
distinguish keyboard release/reset/removal and AX unsubscribe without recording
input. The exact initial HID transport cause is still open. Later staged diagnostics
identified a repeated finalization warning as AX unsubscribe, with keyboard
release/reset/removal confirmed. Finalization now unsubscribes before activating
the assistant, so app switching cannot race the old target subscription. DTX ACK
handling correlates error responses to the requested conversation; an older
error cannot fail a newer unsubscribe, while its own error stays unconfirmed.
Device framing diagnostics then isolated the warning: the current unsubscribe's
single-fragment control reply header declared 16 payload bytes, but the stream
ended before any body byte arrived. There was no semantic-read timeout in that
reproduction. The installed ipb AX client also reports connection-closed-before-ack
separately. Teardown now distinguishes that narrowly correlated empty-reply
closure from an acknowledged unsubscribe, drops the socket in either case and
reports the actual subscription_stop/connection_closed outcome. An unrelated
header, partial body, protocol error, timeout or ordinary semantic request still
fails. This does not establish a successful server ACK or a general TCP fix.
Protocol regressions cover those distinctions; production final-text input completed
without a cleanup warning, while its closure remained explicitly unacknowledged.

A fresh empty-field keyboard turn reported an issued action and the shared
foreground/root-change guard, while the independent receiver remained unchanged. Recovery showed the same app with newly visible keyboard nodes. The
exact transient PID-versus-root branch was not logged. After a focus tap,
press_keys now reuses the existing bounded read-only observation recovery and
verifies the same app, field identity and focus before sending keys. Neither the
focus tap nor input is replayed. The repeated empty-field device check passed;
the exact cause of the earlier transient observation remains unestablished.

During keyboard stop acceptance, a script deadline revoked the phone lease and
stopped a partially delivered key sequence; a new direct-key turn confirmed
modifier release. A later script was refused by the existing preflight live-task
check despite the earlier stop result reporting zero guest processes. The guard
requested an App restart; the kernel/count failure cause is unestablished. This
is separate from DDI keyboard input and must not be described as successful
script-runtime reuse. No script safeguard is bypassed.

The previous errSecInternalComponent development-signing failure no longer
reproduces on a disposable test binary; its cause remains unresolved. Current
candidates can be signed and installed. Private logs, pairing, signing and
success-only records remain local outside Git. No Looktech app/firmware or
schema/rpc change is involved.

## On-device workspace and scripting

Status: implemented by Opus 5.5 on 2026-10-10 and independently reviewed by
Codex and Fable 5.1. Core tests (120), runtime-host tests (7), distribution
tests (7), repository privacy checks and the development Release archive/IPA
inspection pass. Same-identity updates are installed on the iPhone 12 mini
running iOS 27. Existing two conversations and 18 messages, drafts and model
selections remain unchanged through the connected checks.

A fresh import of the fixed bundled rootfs, without the diagnostic cache edit,
runs Bash, Python and Node. Native files/HTTPS, global/project rules and skills,
normal script phone helpers, Stop, timeout, escaped descendants and authoritative
exit status have been exercised on the device. The connected combined script
completed its three phone requests with exit 0 and zero remaining guest
processes. Its full turn continued with streamed model output while Settings
was foreground, returned to PocketAgent and stopped its owned runner. Desktop
runner and port forwarding were stopped before its phone requests. Physical
USB-disconnected validation and benchmark cleanup are still pending; source CI
passes; model inference continues to use the configured API service.
Phone control stays central; projects, rules, files, HTTP and scripts feed it.
Swift and the pinned AgentKit remain the only agent loop.

The user requested an installable release before the remaining physical unplug
check. v0.3.0 (build 3) publishes generic, ad-hoc-signed app and WDA IPAs,
the corresponding source and the Classic source feed. The repository and release
are now public; download or subscribe without GitHub authentication, then re-sign
both IPAs for installation.
The release uses the configured distribution bundle IDs; the bench installation uses
a separate local test identity. Keep that test app installed to retain its local
data, and select the same iCloud Drive folder in the release to import portable
conversations. Credentials, pairing and runner configuration must be set on
each installation. Publication does not close the pending unplugged device gate.

Source lessons from the Opus/Fable review (static reading, not executed):

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

Projects. `WorkspaceStore` keeps app-local projects under Application
Support/PocketAgent/Projects/<UUID> with a small index of IDs and names; the
container path is resolved at use time. A project frozen by a queued or running
turn cannot be deleted (the store asks the chat controller), nor can files
be deleted from it in the file browser (a running script's run folder would
vanish under it; model file tools and editing stay available), and the queue
rechecks the frozen root before starting a turn instead of substituting another. `ChatSession.workspaceID` is a
required nullable local field of the assistant-v1 record; portable sync never
carries it and applying a synchronized snapshot keeps it. The project also sets
the work scope of each accepted request (general without a project). `send` freezes a `WorkspaceSnapshot` into the
job beside the model configuration; a deleted project stops the send with an
explicit notice instead of falling back. External folders are copied in through
the system picker; export writes a copy. AgentKit scratch is not used.

Confinement. `WorkspacePaths` opens the project root and walks each component
with openat(O_DIRECTORY|O_NOFOLLOW); reads use O_NOFOLLOW, writes an exclusive
temporary file plus renameat, removal unlinkat. Symbolic links are listed but
never followed. Every host access to guest-written files (outputs, bridge
requests) uses the same primitive because the guest changes the tree while it
runs. The guest's own view of the project goes through the kernel's hostfs
backend, which is confined separately (see Runtime). `search_files` matches
regular expressions with progress callbacks so Task cancellation or a 15 s
budget stops a catastrophic pattern; directory walks also observe cancellation.

Rules and skills. Each turn loads the global AGENTS.md (Global/ in Application
Support), the project root AGENTS.md and a skills catalog (front matter name and
description from `skills/*/SKILL.md` and `.agents/skills/*/SKILL.md`; project
overrides global) into the system prompt; `read_skill` returns a body. Nested
AGENTS.md inheritance is deferred. A test runs the pinned AgentRuntime with a
capturing model and checks the rule text reaches the actual model request.

Registry. `ToolCatalog` (Core) is the single list: definitions, kinds (phone,
file, context, network, script), the capability prompt, model-call decisions
and script-call decisions. Phone tool names and schemas are unchanged. File
tools need a frozen project, `run_script` a project and a bundled runtime,
`read_skill` at least one skill. Ordinary file, HTTP and script work needs no
per-step confirmation; a script may request phone tools only.

HTTP. `http_request` supports method, headers, text or JSON body (an explicit
JSON null is sent as `null` for body-capable methods), timeout and optional
`save_to` into the project. GET and HEAD treat absent/null JSON and empty text
as no body; actual JSON or nonempty text is rejected with instructions to use
URL query parameters or a body-capable method. This avoids Foundation treating
structured-call null placeholders as a GET entity. Caller-provided headers are
preserved; these bodyless requests do not add a JSON Content-Type automatically.
The enforced contract, for the first URL and every redirect: HTTPS only; no
ports 8100 or 62078; no single-label or .local-style names; no loopback,
private, link-local, CGNAT or multicast address, whether literal or among the
addresses the name resolves to just before the request. URLSession then
resolves the name again and the connection is not pinned to the checked
addresses. TLS authenticates the requested hostname, not the address: it keeps
WebDriverAgent, lockdown and plain LAN services, which hold no trusted
certificate for that name, from receiving request data. Boundary: a server on
a local address holding a publicly trusted certificate for its own public name
can still receive the request if that name's DNS answer changes between the
check and the connection. Closing that would need address-pinned connections
with a hand-written HTTP client (also the only way to offer plain public
`http://`); neither is offered. `timeout_seconds` bounds the whole call,
name resolution included: getaddrinfo runs on its own dispatch thread, the
deadline or Stop ends the wait at once, the late answer is discarded and no
request is sent afterwards. Ephemeral session without cookies, cache or
credential storage; responses are capped at 2 MB with 32 KB returned to the
model. Provider keys are never reachable from it.

The 2026-10-12 iPhone 15 Pro investigation confirmed a request-construction bug:
four HTTP GET calls to three unrelated public hosts all supplied `json: null`;
the old tool encoded it into a four-byte `null` request body. The actual iOS
27.0.1 tool reproduced `NSURLErrorDomain/-1103` before receiving a response,
including for example.com. Apple's iOS 13 release notes document this error
for URLSession GET tasks with a body. The response caps are unchanged; increasing
them would not fix this trigger. Regression tests send the complete structured
GET/HEAD arguments to a local server and check the received body and headers,
while POST/PUT still send explicit JSON null.
The fixed source in a separate native test host on that same iPhone returned
HTTP 200 for example.com, DuckDuckGo and MusicBrainz with zero request-body
bytes, while its explicit old-style GET still returned -1103. The original
SideStore installation was not replaced; the complete shopping conversation
has not been rerun successfully.

The same session had separate phone failures: RP/DDI/Automation/WDA and its first
screen observation succeeded, but an open-app call used the uninstalled
`com.taobao.idlefish`; the installed iOS app was `com.taobao.fleamarket`. Later
phone actions timed out or detected a changed foreground app. The terminal log
records the continued-processing task's expiration/cancellation handler; it
does not distinguish a system stop from cancellation in the task UI. This
session therefore does not establish that initial cellular RP refusal caused
the HTTP error or the final task stop. The 0.3.6 work below addresses installed-app discovery and fresh foreground
recovery; the earlier session itself is not a successful shopping acceptance.

The pre-0.3.6 inventory had 19 tool types. Its saved Xianyu conversation
opened the real app but contained five foreground-change errors; a completed
model status did not prove that the requested information was found.

0.3.6 registers 23 tool types: 15 phone tools, 5 workspace file tools, HTTP,
scripts and skill reading. Files/scripts require a workspace and skills require
a catalog. Installed-app records now expose names and IDs to the model. Native
metadata excludes app extensions and non-application packages: a real device
initially returned both Xianyu and its NotificationService under the name
"闲鱼", so name matching alone was insufficient. The parser uses package,
NSExtension and path metadata rather than suffix guesses. Names must match an
actual reported name for opening; absent or ambiguous names return structured
candidates/errors. Legacy bundle-based opening rejects IDs absent from the
same list. The listing is copied while borrowed, stays only in memory, and is
released before ProcessControl is created.

Phone instructions guide observed search-entry/input/result transitions,
ordinary scrolling, nested-area swipes, visible back buttons and optional edge
back gestures. Spotlight remains optional and is not a release acceptance
requirement. Every navigation returns an actual screen; a gesture does not
establish that the expected page was reached. Typed stale-snapshot/node/geometry
and foreground errors invalidate old references and can attach a fresh read-only
screen. Recovery bypasses system-surface compaction, performs no gesture and
never repeats the interrupted action. A read retry is bounded to two attempts;
mutation retries remain forbidden. Scripts use the same registry and executor.

The independent 15 Pro acceptance host uses the product PhoneExecutor with
the existing SideStore Automation companion, preserving the original app
identity, conversations and settings. Native tool acceptance passed actual
Xianyu name lookup/opening, rejection of the uninstalled guessed ID, text input
and submission, observed matching product results, scrolling with changed
content, and return to the recognized search-input page. An externally changed
foreground caused the old tap to be rejected before issuance and returned a
fresh read-only screen with replay forbidden. The advanced setup view retained
the embedded default hint while a loopback override was saved; the test restored
that override afterward. App-not-found guidance offers home-screen/App Library
navigation and optional Spotlight instead of forcing system search.

An earlier user-started attempt failed before app discovery while the local
VPN was disconnected; reconnecting the existing unchanged VPN restored native
startup. That attempt is not search acceptance or evidence of cellular refusal.
The scripted search entry was adapted to the observed home search container;
button/static-text siblings in the setup page are distinguished by element type.
These acceptance-driver changes are private bench code, not product fallbacks.
The accepted scope is the native tool chain and actual UI, not a complete
model-generated shopping conversation or a SideStore upgrade of the original
app. Spotlight itself and direct cellular-only startup remain unverified/unfixed.
Core tests, distribution tests, the final iOS archive and clean IPA inspection
passed. The 0.3.6 candidate publishes both IPAs, complete corresponding source,
checksums and inspected source metadata. Verify anonymous public source/asset
access and metadata equality after the feed commit.

PhoneExecutor. The former PhoneAgent is now the single phone entry point. AgentKit
phone tools call `executeModel`; script requests call `executeScript`, which
applies the registry's script decision and passes the script's revocable lease
into the shared `perform`. The FIFO lock covers one action; a running script
holds only its lease. `perform` rechecks cancellation, the deadline and the lease
after the runner start/observation awaits and immediately before every effect
request, so an action that was queued, waiting for the lock or waiting for the
runner never issues a new effect after a timeout or Stop. Results distinguish
"not executed" from "issued, unconfirmed — observe before retrying"; an issued
effect is never repeated. Snapshot/node validation and the 100-action limit are
shared, so scripts cannot bypass them. run_script awaits the guest off the main
actor and never re-enters AgentKit, so the sequential tool scheduler cannot
deadlock.

Model context. File, skill, HTTP and script results bound their own size and
point to complete data (offset, `saved_to`, `full_output`), so they are marked
as bounded model content. AgentKit's generic 50 KB projection would otherwise
replace them with a preview that refers to scratch tools this app does not
register and drop `full_output`, `saved_to` and `phone_actions`. The script and
HTTP renderers fit their JSON into the 96 KB host-result limit themselves by
shortening stdout/stderr/body (listed in `shortened_fields`), so the result is
never cut mid-JSON; a run records at most 100 phone actions and counts the
rest in `phone_actions_omitted`.

Runtime. iSH (Linux 5.16 arch/ish, asbestos x86 emulator) at the revisions Operit2
pins, built by `Scripts/ish_runtime.py` with PocketAgent's own patches:
ksetjmp register slots, fakefs rebuild table off the task stack, per-CPU
emulator TLB, gadget table alignment, host isolation, process control,
release build settings and a typed root in the rootfs importer.

- Filesystem. Guest processes cannot mount hostfs or fakefs (kernel context
  only). Every host-side hostfs operation (stat, access, open, opendir, create,
  setattr, symlink, unlink, mkdir, rmdir, mknod, link, readlink, rename,
  statfs) checks its path against the canonical mounted root (no `.`/`..`
  components), opens the parent with O_NOFOLLOW_ANY and acts on the last
  component through `*at` calls without following it (paths are copied into a
  host PATH_MAX buffer because this runs on a 32 KB Linux task stack; longer
  paths fail with ENAMETOOLONG, as the host would). The app canonicalizes the
  root with realpath (iOS /var is a link), verifies it is the same directory
  inside Projects/, and clears the root on unmount, so a detached mount reaches
  nothing. `Tests/RuntimeTests` compiles the patched backend on macOS and races
  a parent-to-outside-link swap against reads, creates, truncates, unlinks,
  renames and mkdirs, after exact un-raced controls (parent in place: every
  operation succeeds; parent replaced by the link: every one is refused); the
  build refuses to continue if anything escapes. A second host test compiles
  the patched setup_user.c and syscalls_user.c (startup bound, egress policy).
- Network. The built backend is GOLP (CONFIG_GOLP; host_inet.c is not
  compiled): the guest has its own IPv4 stack at 10.0.0.1 and GOLP turns its
  TCP connections, UDP datagrams and pings into host sockets through
  `host_connect`/`host_sendmsg`, where loopback, private, link-local, CGNAT,
  multicast and broadcast destinations are refused, plus a host-supplied list:
  the phone's own interface IPv4 addresses (WebDriverAgent listens on all
  interfaces, so a public address assigned to the phone would reach it) and
  the tunnel address, refreshed at mount and every second of a run. Because a
  new phone address can be missing from the list for up to that second,
  destination ports 8100 (WebDriverAgent) and 62078 (lockdown) are refused on
  every address, checked on the guest's sockaddr before conversion. GOLP has no
  host listen/accept, so guest TCP servers are internal; for UDP the host
  socket binds an ephemeral port instead of the guest's port (replies are
  rewritten to the guest port), so no guest service is exposed on a known port.
  IPv6 is not compiled in.
- Processes. `pocket_run_process` uses usermode-helper with UMH_WAIT_PROC:
  uid/gid 501, no capabilities, no_new_privs, a new session and /dev/null on
  fds 0-2. `pocket_user_tasks` counts and signals every live thread of that uid,
  which is exact because only one script runs at a time (RunGate) and is meant
  to include setsid descendants; a process-group or session handle would miss
  them.
- Kernel startup waits at most 60 s (patch 0005 adds a timed variant of
  upstream's unbounded wait_for_startup). The boot thread uses only static
  state, so an abandoned boot cannot touch freed memory; the runtime is then
  poisoned and never reported ready.
- Host calls into the kernel (mount, unmount, task counts, hostname) run as
  work items with a bound (15-30 s); the work item owns its copied arguments,
  so a timed-out caller cannot free them early. A negative task count is never
  treated as zero.
- Poisoning (a bound expired or the kernel panicked) makes every later call
  fail at once and clears the hostfs root, so guest threads that keep running
  reach no project file. A panic no longer ends the app: upstream's panic
  notifier only queued its report and panic() then reached the emergency
  restart, a debug trap (CONFIG_PANIC_TIMEOUT=-1). Patch 0005 reports
  synchronously, ends a startup wait and parks the panicking CPU thread.
  Kernel console lines, including the panic text, go to the device log at the
  default level, and a panic during boot becomes the boot error.
- Build. Upstream only optimizes meson builds for a configuration named exactly
  `Release`; patch 0007 accepts `ReleaseLinux` (now `debugoptimized`, checked
  after the build), passes the path prefix maps through the meson cross file
  (the kernel's CC uses them too), and disables kernel debug info. The kernel
  banner uses a fixed builder identity and date. The build fails if any
  library still contains the checkout/home path or the builder's user@host.
- Rootfs. The pinned i386 Alpine 3.19 image with every package of the closure
  pinned (`alpineRootfs.lock`); setup fails if the repository cannot supply
  exactly that set. Minimal inittab, uid/gid 501, no setuid bits, public
  resolvers; repacked with fixed timestamps, the root directory as the first
  entry and a gzip header without time or name. `verify-rootfs` checks the
  closure, the root entry, required files and setuid bits; the
  Release CI builds the rootfs in a Linux job and the macOS job consumes it. It
  is imported into an app-private fakefs excluded from backup, keyed by the
  archive's SHA-256.
- License. The kernel is GPL-2.0-only and iSH's contributions are additionally
  GPL-2.0 (LICENSE.md, plus the LICENSE.IOS permission), so the runtime and the
  app binary linking it are distributed under GPLv2. Release builds bundle the
  license texts and publish the complete corresponding source next to the IPA:
  repository snapshot, pinned iSH/Linux/libarchive archives, Swift package and
  idevice sources and vendored Rust crates. libapps (terminal UI only) is no
  longer fetched.

run_script. One script at a time. The frozen project is mounted at /workspace
(previous mount detached first, zero leftover threads required);
`.pocketagent/runs/<id>/` holds the script, stdout, stderr, status and bridge.
A wrapper redirects the streams to separate files. The exit is the kernel's
usermode-helper wait status (exit code or signal); the wrapper's status file is
guest-writable and is only compared, with a note on mismatch. A child killed by
a signal appears as the wrapper's exit 128+N. Results carry head/tail-bounded
streams, sizes, duration, nested phone actions and full-output paths; 20 runs
are kept. Timeout is capped by the turn deadline; output above 8 MB per stream
stops the run. Stop and the timeout are observed while the first-use rootfs
import/boot runs (it then finishes, or fails at its bound, in the
background), after setup and after mounting, so no process is started for a
stopped run. Stop order: revoke the lease, SIGINT, two-second grace, SIGKILL,
then poll the kernel until no live thread of the script uid remains; processes
left behind by a finished script are reaped the same way. A nonzero or unknown
remainder is reported and disables scripts until relaunch. If the runtime is
poisoned during a run (panic or expired bound), the run ends at once with that
reason instead of waiting for its timeout. The stop runs in an uncancelled
task; cancellation only sets the flag it observes.

Script phone bridge. `pocketagent-phone` is a two-line launcher in the rootfs
(`/usr/local/bin`) that runs the helper the app writes to `.pocketagent/bin` each
run with python3, so nothing is executed from the project mount. The helper
writes a request file with the run's token into the bridge directory and waits
for the response file. The host serves requests on a separate task, reads them
without following links, executes each request ID at most once and writes
responses by rename; requests left when the lease ends are answered as refused
without executing. The bridge types live in Core and are tested with the real
helper under python3. Sub-actions update the turn's status and are returned in
run_script's own result as `phone_actions`; they never create transcript
messages, so call/result pairing is unchanged. The bridge needs no guest
network path, which is why all guest loopback egress can be refused.

Progress. The status reducer counts phone actions (model or script) separately
from file/network/script steps and shows file, network and script phases; the
folded timeline shows a script's phone actions nested under its step.

Device proof gates (not yet run; source and host evidence only): first-use
import and boot with the default linker (upstream links with -ld_classic);
/dev/null present (upstream `ish_rootfs` in app/LinuxRoot.c mounts devtmpfs
before init); uid 501 file ownership in /workspace; exit code and signal reporting; stdout/stderr
separation; Stop during `sleep 300` returning with zero remaining threads
(including a setsid child and a process whose leader thread exited); a normal
boot within the 60 s startup bound; guest connections to 127.0.0.1:8100, any
address on ports 8100/62078, the phone's Wi-Fi/cellular addresses and the
tunnel address refused while guest DNS, public HTTPS, pip and npm still work
after the ephemeral UDP bind change; a guest UDP bind not reachable on its port; hostfs refusing a guest-created parent symlink swap;
a slow runner launch with a short script timeout issuing no phone effect;
first-use import of the rebuilt archive (root entry) booting to init, and any
later panic leaving the app running with scripts disabled;
HTTPS `http_request` from the app; deleting a project of a queued turn refused;
the composer at 375 points; then speed, cold start, memory and the 48.9 MB
rootfs on the reference phone and the unplugged combined task. Later work:
external security-scoped folders as live workspaces; nested AGENTS.md.

Only PocketAgent's iOS app/runtime and companion integration are affected. The
Looktech Android app, firmware, schema, rpc and audio modules are unaffected
because this introduces no glasses-device contract or algorithm change.

## Delivery and rejected alternatives

Owner: Codex integrator and Opus 5.5 app developer.
For the assistant release, empty initialization, strict current-format
roundtrips/rejection, restart recovery, session isolation, provider selection
capture, sync generation isolation, deletion and concurrent history conflicts
are covered by Core tests; build/install on the reference phone and actual
model/tool execution remain release gates (status in the section above).
IPA/source and repository scans precede GitHub push. Success-only evidence stays
in the parent workspace work/ directory. Synchronization runtime claims require
actual iCloud folder access; multi-device convergence requires two-device proof.

## Confirmed integration problems and fixes

The PR #1 compatibility review reproduced optional-null rejection and nonempty
paste false confirmation using the compiled Core code, and old-patch bootstrap
upgrade failure using an isolated checkout of the pinned idevice revision. Source
inspection also found that native pre-effect refusals poisoned all later input,
and that opening DDI before a failed shared inventory read let later preparation
skip the inventory. The fixes preserve the default routes, current stored data and
no-replay boundary. Native regressions cover refusal versus uncertain effect,
failed release and exact fractional-frame JSON round trips; Core regressions cover
the wire outcome, optional-null policy, placeholder ambiguity and Gemini projection.
Temporary Git-fixture regressions cover patch upgrades, interrupted staging and
preservation of unknown edits. This implementation has renewed Core/native tests,
iOS archive and signed-IPA inspection. On the wired portrait iPhone 12 mini,
the production executor's pre-effect refusal leaves later input usable; optional-null
paste, clipboard denial with explicit AX, placeholder ambiguity and selectable WDA
were checked against an independent receiver. Lease revocation released the received
touch, and a new turn accepted input; the same-turn poison guard remains covered by
native tests rather than that device case. The same-identity update retained existing
IDs, messages, order, deletion records and provider/workspace/rule configuration. A
real configured Responses-model turn completed one read-only observation of the
receiver. This scope does not certify live Gemini requests, arbitrary custom fields,
unplugged startup or active Dynamic Island surface preparation. Success artifacts and
transcripts remain in the private local handoff.

The transcript dismissed the keyboard during interactive scrolling but had no
tap-to-dismiss path. A transcript-only simultaneous tap now clears the root's
existing `FocusState`, leaving the composer outside that gesture. Message
controls receive their tap alongside dismissal; streaming responses do not
change input focus. Interactive scroll dismissal remains enabled.

Session swipe actions used a destructive button merely to request confirmation.
That role lets List anticipate deletion before the user confirms, despite the
store only deleting from the confirmation action. The request is now a normal
red button with full-swipe execution disabled. Only the confirmation's
destructive action removes the row and writes the existing deletion tombstone;
cancel or dismissal keeps the session. Storage, sync and running-session guards
are unchanged.

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

The v0.3.0 companion fails AltStore re-signing with AltSign.Error 4. Confirmed
cause: its `PlugIns/WebDriverAgentRunner.xctest` is absent from AltSign's
`.appex`-only extension discovery, so AltStore fetches a profile only for the
parent app. Release `ResignAppOperation` then visits every direct PlugIns child
and demands a profile for the XCTest bundle. The missing dictionary entry
produces the reported error. This path was reproduced with Foundation bundle
enumeration against the actual release IPA. Inspected sources are AltStore
56854e66fef2eac32dad88dcbad1dc131d430e60 (`ResignAppOperation.swift`,
`FetchProvisioningProfilesOperation.swift`) and its AltSign submodule
790b9ccdaf2cec831689395c527e80f1f2838041 (`ALTApplication.mm`).
The main app contains no PlugIns bundle and does not trigger this condition.
The user subsequently reported successful main-app installation through SideStore.
That does not identify the cause of the earlier OperationError 1008. The screenshot
was from SideStore; the installed client revision is unknown. Current SideStore
0dd743f75afc358b0ba4a002feb5f19474492371 uses SideSign
6b68651697f99791ef85404b7aea1891a26a285d and CodeSignKit
d0c67710fda9a2646b9e829cb2cf443892728371, which recognize XCTest code and
do not share the inspected AltStore's indiscriminate PlugIns preparation path.
The old AltStore mechanism explains its own failure, but attributing that exact
mechanism to the user's unknown SideStore version remains unconfirmed.

v0.3.1 retains the entire XCTest module, resources and nested WebDriverAgentLib
under `Frameworks/WebDriverAgentRunner.framework`. Its executable stays MH_BUNDLE,
its package type stays BNDL, and its relative library paths remain unchanged.
Pinned ldid and CodeSignKit recursively sign this framework hierarchy without
requesting a separate app-extension profile. The main app passes relative
`XCTestBundlePath=Frameworks/WebDriverAgentRunner.framework`; XCTest resolves it
against the runner's current app bundle, including after a signing tool changes
the installation path. No removal of test code or additional provisioning
entitlement is needed. Both apps must be upgraded together; mixed v0.3.0/v0.3.1
installations are unsupported. Same-account, same-bundle-ID updates preserve data.

Preparation changes only the packaging copy. A real Xcode build revealed a
`PlugIns/WebDriverAgentRunner.xctest.dSYM` sibling, so symbol cleanup precedes
the strict test-module migration. Regression tests cover that actual layout,
retention of resources/library/executable metadata and rejection of unexpected
PlugIns code or a conflicting destination. The original build products remain
unchanged. Core tests (120) and distribution tests (17) pass; the Release app
archive and WDA build-for-testing succeed. The prepared companion passes local
development signing and deep signature verification. Pinned ldid signing of a
separate framework-layout fixture also passes deep signature verification;
that fixture is structural signing proof, not Apple-profile installation proof.

The development prototype installs separately on the 12 mini. Launch using the
exact minimal relative environment used by the app reached the system's UI
Automation passcode authorization page. The owned runner later exited while
authorization remained pending; that does not establish a framework-loading
failure or successful WDA startup. The temporary probe remains installed under
recorded ownership to retain the system authorization page; it has not replaced
the original app. User input is pending, followed by a retry with the same
minimal environment. Actual AltStore/SideStore re-sign/install verification and
runtime validation of this layout remain open. Existing conversations must be
retained through the same-identity upgrade. Success-only logs and snapshots stay local.

The fix is committed at 480e0be. Its clean GitHub validation and full IPA workflow
both pass. `candidate-0.3.1` publishes the locally inspected generic pair,
corresponding source and checksums as a prerelease. Initially only the candidate
release was published, leaving the main-branch feed at 0.3.0; refreshing a
sideloading client therefore could not discover 0.3.1. At the user's request,
the feed now offers 0.3.1/build 4 for both apps, using the existing candidate
asset URLs and their inspected sizes and SHA256 hashes. Earlier versions and
v0.3.0 assets remain available. Feed descriptions, README and release notes
identify the candidate and distinguish packaging/signature checks from pending
actual client installation and phone runtime. After system authorization,
verify WDA startup and a same-identity native app update with all current data
retained before publishing a stable tag.

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

First Release device build after adding the runtime stalled for minutes in
Swift's explicit module dependency scan. `Native/launch.h` shadowed the SDK's
`<launch.h>`, which `xpc.h` includes; once the native module also imported
Foundation this formed a Foundation → XPC → PocketAgentNative → Foundation
cycle. The header is now `pocketagent_launch.h`; a non-explicit-module build
surfaced the cycle error that the explicit scan never reported.

Peer review found that checking a resolved real path and then opening it lets a
concurrently swapped parent directory (a symbolic link the guest creates) lead
outside the project; a race test reproduced one escaped read in thousands. All
workspace access now walks anchored descriptors with O_NOFOLLOW, and the
regression swaps the parent 20,000 times without an escaped read or write. The
same review moved bridge service off the monitoring loop so a deadline or
cancellation can revoke a script while a phone action is in flight, and made
task counting per thread so a process whose leader exited is still found.

The first hostfs hardening added O_NOFOLLOW only to final components, and the
first report overstated it as closing host path races. Compiled on macOS with
the exact header, the backend still read an outside sentinel when a parent
directory was swapped for a link (8 reads, 1 outside), and the new harness
showed write-side escapes too (outside directory modified). Every hostfs path
operation is now anchored as described under Runtime; the same harness reports
no outside read or change. Reachability through the guest VFS is a device
check.

Search had no cancellation point: `(a+)+$` on a 50 KB line ran inside
NSRegularExpression.firstMatch for more than 2 s after cancellation. Matching
now uses enumerateMatches with progress callbacks; a 0.1 s cancellation returns
in about 0.1 s and a 0.2 s budget ends with a budget error.

The runtime preferred the guest-written status file over the kernel wait
status. A wrapper whose child wrote 0 and then SIGKILLed the wrapper returned
-9 to its parent while the file said 0, which would have been reported as
success. The kernel status now decides; the file is a cross-check.

A script phone request checked its lease before the action and then awaited
runner start; a timeout revoking the lease meanwhile was not seen, and the
action went on to issue a new effect. `perform` now rechecks before each effect.

The first HTTP revision discarded responses whose measured peer was private,
described as closing DNS rebinding; the request and body had already reached
that peer. The contract is now HTTPS-only with the checks described under HTTP;
the post-response check was removed. A later revision overstated TLS as closing
rebinding apart from a user-installed root; it proves the hostname only, as the
HTTP section now states. The URLSession timeout was only an inactivity timeout;
a dripping server now ends at the whole-request limit.

The whole-request limit still did not cover name resolution: the resolution was
awaited as a detached task, which cancellation does not interrupt, and the
task group waited for it. With getaddrinfo interposed to take 5 s, a 1 s limit
returned after 5.0 s. The wait is now cancellable (resolution on its own thread,
a once-only continuation, a cancellation check before the request); the same
probe returns after 1.0 s, and a regression with a slow injected resolver
covers the deadline, Stop and a slow redirect target, with no request sent
afterwards.

The first device run_script (integrator's preliminary build) ended the app
with EXC_BREAKPOINT during first-use preparation, in the kernel's panic path.
The device log showed `read_inode: unexpected S_IFMT: 0`, the fakefs root
mount failing with EIO and "No working init found". docker export has no
entry for the archive root; iSH's importer then adds the root with mode 0755
and no file type, which the kernel cannot read. Setting that one cached mode
to a directory let the same build boot and run Bash, Python and Node scripts,
which confirmed the cause. The repacked archive now starts with the root
directory (verify-rootfs requires it, and the new archive digest forces a
fresh import), and patch 0008 gives the importer's fallback root the
directory type. Before booting, the app now checks that an import's root entry
is a directory and that /sbin/init exists, and re-imports a cached root that
fails (the defective cache on the phone is replaced either way, because the
archive digest changed). The crash itself came from panic() ending in the emergency
restart, a debug trap; a panic now poisons the runtime instead (see Runtime).

PocketISHBoot bounded the work items after boot but called upstream's
actuate_kernel, whose wait_for_startup waits on a condition variable without a
bound, so a kernel that never reached its late initcalls would hang the first
script forever and hold the boot lock. Startup now uses the timed wait above.

The hostfs race test asserted more than 100 successful reads; one run had 84
with nothing escaped, so the threshold depended on scheduling. It now checks
exact un-raced controls, then races until successful reads, successful writes
and link refusals have all occurred. Against the earlier final-component-only
backend the linked control reads and changes the outside directory on every
run, so detection no longer depends on winning the race.

Fable's runtime review (confirmed by Codex) found `ReleaseLinux` built the
emulator and fakefs at -O0 with assertions, the guest able to reach the phone's
own public address and to bind fixed host UDP ports, home paths in the runtime
libraries, non-deterministic gzip headers, an unpinned package closure, a
rootfs import keyed by byte size, unbounded host waits on the kernel and the
hostname set on a host thread; all are fixed as described above. The IPA check
of this revision also found the builder's user@host and build time in the
kernel banner; the kernel identity is now fixed and the build scans for it.
Fable's app review found project deletion ignoring queued/running turns, host
results losing `full_output`/`saved_to`/`phone_actions` to AgentKit's preview,
Stop not observed before process start, and untested bridge types; fixed as
above. Its suggestion to cancel by session instead of uid was not taken (setsid
descendants would escape).

A header-injection test passed "a\r\nB: c" as a header value: Swift treats
"\r\n" as one Character, so `contains("\r")` was false. Header names and values
are now checked by Unicode scalar for control characters.

On the iPhone 12 mini (375 pt) the composer row kept the model and provider
names and clipped the selected project to its icon and part of one letter.
The row now drops the provider name first and then shows the project as its
icon only (the full name stays its accessibility label); a name is never
clipped mid-word, and the model name stays first.

The new linker warned that emulator gadget tables had byte alignment; the gadget
array macro now aligns them to 8 bytes. Kernel and emulator builds now map the
checkout and home paths so no local path remains in the stripped app binary.

A connected-device turn with another app in front was expired by the system
~71 s after submit and ~35 s into the second run_script call (script slept 20 s, printed, then requested phone
actions): Root never pressed Stop, guest processes were 0 and no phone action
was replayed. dasd logged "Task has not reported progress within expected
cadence, marking stalled (time without update ≈31.7 s)" — the last completed
unit change was at run_script start — then Activity Progress Policy suspended
the task and the expiration handler fired. The log confirms system progress-policy expiration. It does not isolate
early progress publication from gaps in real-work reporting: the daemon record
read 0/0 and the old app had no local publication metadata. Its gap matches
the old event mapping, which advanced only on finished messages/steps and
ignored script output. The combined fix initializes one stable Progress before
the launch callback returns and reports actual intermediate work. On-device
retest completed the same combined script and a background streamed response
without stalling; the captured Progress identity stayed stable. A separate
90-second silent interval also completed normally. These observations verify
the repaired flow, not a fixed system cadence or one isolated cause. Now real work
inside a step advances a `workObserved` counter that feeds only
`progressUnits` (visible step counts unchanged): streamed model/reasoning
chunks (at most one unit per 5 s), script runtime ready, process started,
stdout/stderr growth (at most once per second) and script phone requests. No
timer or fabricated percentage; total stays completed + 1. The launch handler
sets 0/1 on `task.progress` synchronously and the turn keeps that one object;
`task_progress` logs counts and the event kind on each change. The status and
run ID are fixed when the turn is accepted (so `elapsed` counts from submit),
and the launch handler installs the expiration handler synchronously, before
any main-actor hop. On the main actor it acts only if that run is still the
current, busy, non-terminal turn — a queued callback from a finished turn
cannot cancel the next one — then marks the status expired, logs
`background_task_expired` (counts, phase, seconds since the last change) and
cancels. An expiry before the turn body starts leaves a pending cancellation,
so the body stops before any work and fails with the expiry cause. An expiration (system, or dismissal from the system task
UI) ends an unsuccessful turn as failed with a send-a-new-message cause;
a turn whose agent already completed successfully keeps its completed outcome.
Remaining limit: iOS can expire a task with no observable progress, including
a silent script or a provider that streams nothing. The earlier stall occurred
at about 32 seconds without an update, but the later silent interval of
90 seconds completed without expiration; no fixed threshold is claimed.
The run_script descriptor
tells the model to print real intermediate output from long scripts (for
example after each finished chunk), never heartbeats or fake progress.

A hosted CI cancellation test failed its two-second bound while measuring from
before detached-task launch and the pre-cancellation wait. That interval could
not isolate cancellation latency. The regression now uses a monotonic clock
starting immediately before `cancel()`, keeps the same two-second bound and
requires the exact CancellationError. No production search change or scheduler
root cause is inferred from that failure.

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
that ordinary AltStore personal accounts cannot assume. Migrating to Operit2's
Rust/Flutter agent framework would replace the verified AgentKit loop. A
loopback TCP bridge with a token would require reopening guest loopback egress,
which is the path to the unauthenticated WDA listener. A new generic database
or storage abstraction is unnecessary for this scope. Secret synchronization is
not part of portable conversation data.
