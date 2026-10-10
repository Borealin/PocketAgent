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
the corresponding source and the Classic source feed in the private repository.
Download with GitHub authentication and re-sign both IPAs for installation.
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
rechecks the frozen root before starting a turn instead of substituting another. `ChatSession.workspaceID` is an optional
local field (decoded if present, so current history keeps every ID, message,
draft, selection and attribution); portable sync never carries it and applying a
synchronized snapshot keeps it. `send` freezes a `WorkspaceSnapshot` into the
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
JSON null is sent as `null`), timeout and optional `save_to` into the project.
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
