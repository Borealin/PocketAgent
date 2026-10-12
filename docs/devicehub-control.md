# Device Hub services for phone control

> Status: native DDI implementation completed; device acceptance in progress. User selected DDI as default with a selectable WDA backend on 2026-10-12. Main baseline: `f8f82a4` (14 phone tools).
> Readers: PocketAgent app and native (idevice FFI) developers.
> Scope: whether PocketAgent's phone tools can run on the developer disk image (DDI)
> services that Xcode 27 Device Hub uses, instead of the WebDriverAgent (XCTest) runner.

## 1. Requirements and references

| Type | Link | Notes |
|---|---|---|
| Requirement | None (user request, 2026-10-12) | No tracked requirement record |
| Figma | Not applicable | Existing phone settings gain a backend selector |
| Prerequisite design | [engineering.md](engineering.md) | RP tunnel, DDI preparation, runner lifecycle and phone tools |
| Related research | [ipb at 1a3618e](https://github.com/ipbtools/ipb/tree/1a3618ebcb6117466accebb455bf4e2e445fa9d6) | MIT-licensed Mac client for the same services; device records in `docs/verification.md` |
| Library | [idevice at 3854a5d](https://github.com/jkcoxson/idevice/tree/3854a5df4a5a6dee71ffce4d8befc2ea356a8065) | PocketAgent's pinned revision; service clients in `idevice/src/services/core_device/` |
| DDI source | [DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) | PocketAgent downloads `PersonalizedImages/Xcode_iOS_DDI_Cryptex` from `main`, unpinned |

The earlier main implementation performs phone actions by launching the WebDriverAgent runner (the Automation
companion) through DVT and calling its localhost HTTP API. That path needs a separately
signed companion app, testmanagerd's Automation Mode authorization on the phone and a
runner start and stop for every turn; a runner launch failure and an authorization
timeout are among the recorded integration problems. ipb shows that Device Hub drives an
iPhone without XCTest: DDI daemons provide touch, keyboard and buttons, screenshots,
clipboard and app launch, and the system accessibility audit service provides the UI
element graph. PocketAgent's RP tunnel already reaches the same RSD service list. This
document records the implemented backend, confirmed integration failures and the device-specific verification boundary.

- Scope: the native DDI backend behind main's existing 14 phone tools, with an explicit WDA selector and the same action safety contracts.
- Non-goals: removing WDA, which stays selectable; the cellular RP
  connection problem in engineering.md, which sits below this layer and is unaffected;
  answering system dialogs or paste permission prompts automatically; Mac-side tooling
  such as devicectl.

## 2. Research conclusions

- Decision: implement DDI as the default and retain an explicit WDA selector. Never
  switch backends or replay an action automatically after an uncertain result.
  A separately signed native probe reused PocketAgent's pinned idevice
  and tunnel patch on an iPhone 12 mini. Screenshot, ordinary touch, app launch and
  Home worked through its on-phone RP tunnel without starting XCTest or WDA.
- The stream requirement is disproved for ordinary touch on this tested combination:
  iOS 27.0 / 24A437, mounted DDI 27A5252f, CoreDevice 642.15. Before the no-stream
  tap the display service reported an empty session list and `running=false`; the
  native counter changed from 0 to 1. With a stream it changed from 0 to 1, and after
  explicitly stopping that stream it changed to 2. Do not generalize this to another
  iOS/DDI build or infer the cause of idevice's contradictory module comment.
- Confirmed from sources: the transport is the same; the DDI that PocketAgent downloads
  contains every needed daemon; the pinned idevice has clients for all of them, but its
  FFI exports only app_service among them.
- Production implementation: bounded AX graph traversal and role mapping, native screenshots, owned HID input and app launch are integrated with the existing executor. Device acceptance is still in progress.
- Remaining boundary: long background lifetime, physically unplugged operation, system-dialog input and PocketAgent's downloaded DDI are not established by the initial probe.
- Main tradeoff: DDI removes the companion, XCTest and Automation Mode authorization, but uses private interfaces and a shallower AX graph. This implementation accepts portrait geometry and briefly returns to PocketAgent to prepare Unicode input; the target may ask for paste permission. Keyboard dismissal is an Escape request and requires fresh-state verification.

<details>
<summary>Research details and sources</summary>

### Candidate comparison

| Candidate | Advantages | Cost / risk | Conclusion |
|---|---|---|---|
| WDA compatibility backend | Hierarchical source, element types, verified tool semantics | Companion signing, Automation Mode authorization, per-turn runner lifecycle | Keep selectable; no automatic action fallback |
| DDI services through idevice FFI | No companion or XCTest; same tunnel; faster element reads | Shallow AX graph; private interfaces; portrait only; text preparation can switch apps | Production backend implemented; complete device acceptance in progress |
| DDI observation with WDA input | Faster observation, independent of the stream question | Keeps the runner and its authorization | Fallback if DDI input proves impractical |
| pymobiledevice3 on the phone | Complete implementation | GPL-3.0; adds a Python runtime | Rejected |

### Tool mapping

| Main tools | DDI implementation | Boundary |
|---|---|---|
| observe_screen | Bounded AXChildren graph, native screenshot, read-only foreground hit scan and unique process-path match | Unknown foreground and unverified geometry fail |
| find_apps | Streamed AppService inventory and shared name matching | Installed apps only |
| open_app, open_app_by_name | AppService activation without terminating the existing process | Shared ambiguity and installed-app checks |
| tap, tap_point, long_press | Owned touchscreen contacts | Snapshot, foreground and geometry checks precede effects |
| swipe, swipe_from_to | Bounded touchscreen path | Shared coordinate/duration limits |
| type_text | Foreground UIKit clipboard preparation, actual-content readback, target restoration, clear verification and HID paste | Brief App switch; paste permission may require the user |
| press_key | Owned mainKeyboard Return/Delete | Explicit key-up reports and empty held-key state |
| dismiss_keyboard | Escape and shared fresh observation | Unconfirmed dismissal is reported |
| press_home | Owned Indigo Home down/up | Releases before returning |
| wait | Existing local wait | Unchanged |

### Sources

- idevice 3854a5d (2026-10-08): the `hid.rs` module header states that the device drops
  every dtuhidd event kind unless a displayservice media stream is active, and that the
  stream only needs to exist while events are sent; its CLI (`tools/src/hid.rs`) opens a
  stream around every gesture. `display_stream/`, `screencaptureservices.rs`,
  `pasteboard_service.rs` and `app_service.rs` sit beside it. `ffi/src/core_device`
  exports app_service but not HID, display stream, screen capture or pasteboard, and the
  FFI `full` feature list omits `display_stream`.
- ipb 1a3618e, `docs/verification.md`: on 2026-09-07 a client with no CoreDevice host
  stack tapped the App Library search field on iOS 27.0 beta 24A5430a with DDI 27A5252f
  and CoreDevice 642.15; no stream is recorded for that run. The 2026-10-11 pass on
  release 24A437 ran through ipb's mirror, itself a displayservice stream, so it does not
  discriminate.
- ipb AX versus XCTest baseline on iOS 27.0: Settings main returns 13 AX nodes at depth 1
  versus 176 XCTest nodes at depth 21, with all 12 non-root AX elements matched and
  identical native frames; Calculator returns 24 versus 45. Settings query medians were
  186 ms versus 2710 ms, over different field scopes. `Sources/ipb_ax.py` reaches the AX
  service as an RSD-advertised port; its DTX transport comes from pymobiledevice3.
- ipb Gap 2: Device Hub can tap system dialogs and ipb cannot. A `remoteTimestamp = 0`
  hypothesis was not confirmed; the root cause is open.
- The DDI PocketAgent downloaded on 2026-10-12 (bundle version 27.1.5228.8, build
  27A5228h, CoreDevice 642.4), mounted read-only on a Mac for inspection, contains
  dtuhidd, dtscreencaptured, dtpasteboardd, dtappserviced and dtremotedisplayd.
  PocketAgent mounts its download only when no DDI is installed, so the build in use on
  a phone depends on what mounted it.

### Rejected alternatives

- pymobiledevice3 on the phone: GPL-3.0, while the shipped binary is GPLv2 because it
  links iSH (engineering.md, License). idevice already provides the RSD and DTX layers.
- Driving the phone from a Mac through devicectl, Device Hub or ipb: phone actions must
  keep working without a Mac attached.
- Removing WDA in the same change: the user explicitly selected a manual WDA option; other geometries and private-interface version changes need a compatibility path.

</details>

## 3. Technical design overview

Add a backend boundary inside the existing phone executor. Tool names, parameters,
snapshot IDs, approvals, the single serial action queue and the no-replay rule stay as
they are. DDI is the default; WDA is selected explicitly. Backend selection is frozen
when a turn is queued and never changes during that turn. A DDI backend reuses
the turn's RP tunnel and DDI preparation, skips runner launch and opens service clients
through new idevice FFI exports. It observes with a screenshot plus the AX graph and
acts through dtuhidd and dtappserviced; the phone app prepares UIPasteboard in its foreground before input, restores and validates the target, and checks actual clipboard text with a fresh read-only service connection. The tested matrix does not require
an always-on display stream for ordinary touch, Home or ASCII keys. If another supported
matrix establishes that requirement, the turn must explicitly own and tear down its
stream, as it owns the runner PID today; do not silently introduce screen sharing or
retry an action after discovering that its outcome is unknown.

<details>
<summary>Detailed design</summary>

### Implementation contract

- Align with main `f8f82a4`: all 14 phone tools, installed-app names and IDs,
  ordinary system navigation, bounded coordinate swipe and fresh-observation recovery. Model and
  script callers continue through the existing PhoneExecutor action queue.
- Swift owns one native DDI session per turn. Native requests have deadlines;
  cancellation releases contacts/keys and removes only the owned keyboard before
  releasing services. No display stream is started on the proven device matrix.
- AX archives are decoded as bounded data, never instantiated Apple classes.
  One semantic request at a time; abort the AX connection on timeout so a late
  response cannot be assigned to another element. Traverse AXChildren, validate
  foreground PID and display geometry before/after, then map observed roles to
  tool types without inventing missing attributes.
- Unicode input uses UIKit to replace the device clipboard and a virtual keyboard paste
  chord. Clear and paste are separate effects with stop checks. Permission prompts
  and unconfirmed input/dismissal are reported with the actual fresh screen.
- Scope excludes a floating overlay and embedded VPN. RP pairing, LocalDevVPN
  routing and cellular startup constraints remain prerequisites.

### Impact and compatibility

| Area | Affected | Reason | Module | Compatibility |
|---|---|---|---|---|
| PocketAgent app | Yes | New backend behind the phone tools | `App/PhoneAgent.swift`, `App/Controller.swift`, `App/Core/ToolCatalog.swift` | Explicit WDA selector; same tool schemas |
| PocketAgent native | Yes | New FFI exports and the `display_stream` feature | `Native/idevice.h`, `Native/idevice.patch`, `Scripts/bootstrap.py` | Same pinned idevice revision |
| Automation companion | No change in this phase | Remains the fallback | WDA runner | Removal only after parity |
| Looktech Android and iOS apps, Bluetooth and ISP firmware, schema, rpc, lt-vad | No | No glasses-device contract, protocol or audio algorithm change | None | None |

### Current design to target design

| Current module | Current responsibility | Relation | Change |
|---|---|---|---|
| `App/Controller.swift` device connection | RP tunnel, RSD handshake, DDI check and install, DVT runner launch and stop | Extend | Keep tunnel and DDI; own DDI service sessions without a stream on the tested matrix; launch the runner only for the WDA backend |
| `App/PhoneAgent.swift` | WDA HTTP calls, snapshot and node mapping, effects | Extend | Move WDA calls unchanged behind a backend protocol; add the DDI backend |
| `App/Core/ToolCatalog.swift` | Phone tool specs | Keep | Same names and parameters; backend-specific capability text where semantics differ |
| `Native/idevice.h`, `Native/idevice.patch`, `Scripts/bootstrap.py` | FFI surface, local idevice patch, build features | Extend | Export owned HID, screen capture and AX sessions; compile `display_stream` for the HID client, without starting media |
| None | None | New | AX reader: port ipb's MIT-licensed AX request dialect onto idevice's DTX support; copy nothing from pymobiledevice3 |

### State and main flow

- Ownership follows the turn: the turn that starts automation owns the tunnel, the DDI
  service session and, if required, the display stream. Teardown runs without inherited
  cancellation, as for the runner today.
- One action at a time on the existing serial queue. Every action ends with a fresh
  observation, and node actions must name the latest snapshot.
- An action whose outcome is unknown, such as a closed handle or a timeout, is never
  replayed; the next step observes first. A closed HID connection does not prove that
  the event did not land.
- Foreground clipboard preparation may briefly switch apps. Direct input into unlisted
  system processes, including Spotlight, is refused; select WDA when that input is needed.
- System dialogs and paste permission prompts are reported as needing the user's action
  on the phone. Gap 2's root cause is open, and this design does not depend on it.
- If the hit test cannot name the foreground app, the observation says so instead of
  guessing.
- No new entitlement, stored secret or synchronized data. Pairing data stays local.

### Implementation and acceptance order

1. Retain the completed experiment's material outside the repository. Recheck other
   iOS/DDI combinations before assigning them the same stream policy.
2. Observation: export screen capture and add the AX reader. Neither depends on the
   stream question.
3. Introduce the backend protocol in the phone executor with WDA moved behind it
   unchanged.
4. Add the input exports (HID and phone-local clipboard preparation) and the DDI
   backend behind the local DDI/WDA selector.
   Keep stream ownership optional for the tested matrix; do not add a permanent
   screen-sharing session solely on the basis of the idevice module comment.
5. Make DDI the default only after core tests, the iOS build, IPA inspection and the
   exact-device exercise pass.

### Experiment scope and remaining checks

The completed ordinary-input control used the user-selected iPhone 12 mini. The
remaining system-dialog and version-matrix checks follow this procedure. On one phone,
through PocketAgent's tunnel path rather than devicectl, and with no
Mac-side Device Hub or mirroring session open: send the same tap to a harmless target
without a display stream and then with one active, confirming each by screenshot. Then,
with a system alert on screen, record whether a tap lands, without attempting a
workaround. Record the iOS build, the mounted DDI build and the CoreDevice version for
every run: ipb's no-stream evidence is from beta 24A5430a with DDI 27A5252f, current
release builds are 24A437 (iOS 27.0) and 24A446 (iOS 27.0.1), and PocketAgent's own
download is 27A5228h. If the stream is required, also measure its setup time, whether a
screen-sharing indicator appears and its power cost.

### Initial feasibility boundary (before production integration)

- The local probe was built for iOS, development-signed, installed on the selected
  iPhone 12 mini and exercised. Its development IPA was checked for signature validity
  and absence of a pairing file. Pairing was transferred separately into its local
  data container, which is excluded from backup. The installed PocketAgent and its
  history were not replaced.
- The probe reused idevice 3854a5d plus this branch's `Native/idevice.patch` and the
  same local-network permission / `tunnel_create_rppairing` path. Device-side services
  provided the screenshots, taps, Calculator launch, the visible `7 + 5 = 12` result
  and Home return while the probe was in the background. No Mac port forward,
  Device Hub viewing session, XCTest or WDA runner provided these actions; USB
  remained attached for installation and result retrieval.
- The no-stream / active-stream / stopped-stream control described above resolves
  the proposed mandatory stream assumption only for this matrix. The temporary stream
  showed the system screen-sharing indicator;
  power consumption and long media lifetime were not measured.
- The mounted DDI was 27A5252f / CoreDevice 642.15, not the inspected PocketAgent
  download 27A5228h / CoreDevice 642.4. Both host and device versions are part of the
  experiment boundary; the Mac was macOS 26.5.1 with Xcode 26.5 selected.
- A native raw-DTX AX probe completed requests 6 → 1 → 5 through the same on-phone
  RP adapter. The decoded responses had error 0 and identified the probe application
  root, its 375 × 812 point frame, description and three child handles. Native code
  sent the requests and stored their replies; the Mac decoded those artifacts afterward.
  This establishes service/dialect access, not a complete graph traversal or a
  production observation adapter.
- A separate no-stream keyboard probe created a mainKeyboard service, sent `a`, `b`,
  `c` and Backspace, and removed the service successfully. The field visibly contained
  `ab`; IME composition, arbitrary Unicode and cross-app text delivery are separate checks.
- Initial connection attempts returned `No route to host` before DDI access. The local
  VPN was disconnected, and the new probe had not yet completed local-network and
  wireless-data permissions. After connecting the existing VPN and completing those
  system prompts, the same RP endpoint connected. These failures cannot diagnose the
  HID/display-service layer.
- A separate Mac-side cleanup check exposed a boundary: ipb's no-stream tap returned
  successfully but the VPN page still showed Connected in two fresh observations.
  With a temporary Mac-side stream, the same control disconnected the VPN. Its root
  cause is unestablished; this is a host-client observation, not a native RP failure
  or proof that a stream is universally necessary. Cleanup restored the original
  disconnected VPN state and a final display-service read showed no running stream.
- These initial probes preceded the production backend and cannot substitute for its core/build/IPA/runtime gates. Physically unplugged operation, system-dialog behavior and other iOS/DDI matrices remain outside the demonstrated scope.

</details>

## 4. Implementation status and remaining acceptance

| Module | Repository | Owner | Branch | Status |
|---|---|---|---|---|
| Backend selection and frozen job configuration | PocketAgent app | Codex | devicehub-control | Implemented: DDI default, manual WDA |
| Native screenshot, bounded AX reader and role mapping | PocketAgent app/native | Codex | devicehub-control | Implemented |
| Touch, keyboard, Home, clipboard and cancellation ownership | PocketAgent app/native | Codex | devicehub-control | Implemented; complete executor exercise in progress |
| Build, clean IPA, exact-device update and history preservation | PocketAgent | Codex | devicehub-control | Acceptance in progress; no public feed update |

The user authorized implementation and exact-device validation on the iPhone 12 mini.
The current work does not embed a VPN or add a floating overlay. RP pairing and local
VPN routing remain prerequisites. Other iOS/DDI matrices, system permission-dialog
control and physically unplugged operation are follow-up validation, not implied parity.
Confirmed integration fixes and their remaining root-cause boundaries are condensed
in [engineering.md](engineering.md#ddi-phone-backend-2026-10-12). Success-only evidence
and private signing/pairing stay outside version control.
