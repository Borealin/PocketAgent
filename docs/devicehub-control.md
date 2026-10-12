# Device Hub services for phone control

> Status: design in progress; nothing is implemented. Last checked: 2026-10-12.
> Readers: PocketAgent app and native (idevice FFI) developers.
> Scope: whether PocketAgent's phone tools can run on the developer disk image (DDI)
> services that Xcode 27 Device Hub uses, instead of the WebDriverAgent (XCTest) runner.

## 1. Requirements and references

| Type | Link | Notes |
|---|---|---|
| Requirement | None (user request, 2026-10-12) | No tracked requirement record |
| Figma | Not applicable | No UI change is proposed yet |
| Prerequisite design | [engineering.md](engineering.md) | RP tunnel, DDI preparation, runner lifecycle and phone tools |
| Related research | [ipb at 1a3618e](https://github.com/ipbtools/ipb/tree/1a3618ebcb6117466accebb455bf4e2e445fa9d6) | MIT-licensed Mac client for the same services; device records in `docs/verification.md` |
| Library | [idevice at 3854a5d](https://github.com/jkcoxson/idevice/tree/3854a5df4a5a6dee71ffce4d8befc2ea356a8065) | PocketAgent's pinned revision; service clients in `idevice/src/services/core_device/` |
| DDI source | [DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) | PocketAgent downloads `PersonalizedImages/Xcode_iOS_DDI_Cryptex` from `main`, unpinned |

PocketAgent performs phone actions by launching the WebDriverAgent runner (the Automation
companion) through DVT and calling its localhost HTTP API. That path needs a separately
signed companion app, testmanagerd's Automation Mode authorization on the phone and a
runner start and stop for every turn; a runner launch failure and an authorization
timeout are among the recorded integration problems. ipb shows that Device Hub drives an
iPhone without XCTest: DDI daemons provide touch, keyboard and buttons, screenshots,
clipboard and app launch, and the system accessibility audit service provides the UI
element graph. PocketAgent's RP tunnel already reaches the same RSD service list. This
document records what is confirmed, the open question that decides the architecture and
the experiment that answers it.

- Scope: feasibility, a backend design behind the existing phone tool names, the
  discriminating experiment and the FFI/AX work it would unlock.
- Non-goals: removing WDA, which stays the default and the fallback; the cellular RP
  connection problem in engineering.md, which sits below this layer and is unaffected;
  answering system dialogs or paste permission prompts automatically; Mac-side tooling
  such as devicectl.

## 2. Research conclusions

- Recommendation: do not commit to replacing WDA yet. First run one discriminating
  experiment on a single phone through PocketAgent's own tunnel; its result decides
  whether the DDI backend must hold a display stream, which changes the lifecycle and
  cost design below.
- Confirmed from sources: the transport is the same; the DDI that PocketAgent downloads
  contains every needed daemon; the pinned idevice has clients for all of them, but its
  FFI exports only app_service among them.
- Open, root cause not established: idevice states that dtuhidd input is dropped unless a
  displayservice media stream is active, while ipb recorded a tap landing without one.
- Main tradeoff: the DDI path removes the companion app, XCTest and the Automation Mode
  authorization and reads UI elements faster. It loses element hierarchy and types, has
  no dismiss_keyboard equivalent, could not tap system dialogs in ipb's tests, can raise a
  paste permission prompt for arbitrary text and depends entirely on private interfaces.

<details>
<summary>Research details and sources</summary>

### Candidate comparison

| Candidate | Advantages | Cost / risk | Conclusion |
|---|---|---|---|
| WDA only (current) | Hierarchical source, element types, verified tool semantics | Companion signing, Automation Mode authorization, per-turn runner lifecycle | Keep as default and fallback |
| DDI services through idevice FFI | No companion or XCTest; same tunnel; faster element reads | Stream question open; flat graph; private interfaces; gaps below | Pending the experiment |
| DDI observation with WDA input | Faster observation, independent of the stream question | Keeps the runner and its authorization | Fallback if DDI input proves impractical |
| pymobiledevice3 on the phone | Complete implementation | GPL-3.0; adds a Python runtime | Rejected |

### Tool mapping

| Tool | DDI path | Notes |
|---|---|---|
| observe_screen | AX graph from `com.apple.accessibility.axAuditDaemon.remoteAXService`; dtscreencaptured screenshot; foreground PID from an AX system hit test, bundle ID from the dtappserviced process list | Flat graph; ipb found the AX frontmost query can name an unrelated process, and its hit test is a tested strategy, not universal overlay coverage |
| open_app | dtappserviced launch | The FFI already exports app_service |
| tap, tap_point, long_press, swipe | dtuhidd touchscreen reports | Stream question; system dialogs (ipb Gap 2) |
| press_home | dtuhidd button event | idevice applies the stream requirement to buttons too |
| type_text, press_key | dtuhidd keyboard; arbitrary Unicode through dtpasteboardd and a paste shortcut | iOS can ask the focused app to allow paste from dtpasteboardd |
| dismiss_keyboard | No equivalent found | Gap |
| wait | Local | Unchanged |

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
- Removing WDA in the same change: tool parity (hierarchy, element types,
  dismiss_keyboard) is unproven, and WDA remains the only verified path.

</details>

## 3. Technical design overview

Add a backend boundary inside the existing phone executor. Tool names, parameters,
snapshot IDs, approvals, the single serial action queue and the no-replay rule stay as
they are; WDA becomes the first backend and remains the default. A DDI backend reuses
the turn's RP tunnel and DDI preparation, skips runner launch and opens service clients
through new idevice FFI exports. It observes with a screenshot plus the AX graph and
acts through dtuhidd, dtappserviced and dtpasteboardd. If the experiment confirms the
stream requirement, the turn that starts automation owns one display stream for as long
as it owns phone actions, as it owns the runner PID today, and discards the video
payload.

<details>
<summary>Detailed design</summary>

### Impact and compatibility

| Area | Affected | Reason | Module | Compatibility |
|---|---|---|---|---|
| PocketAgent app | Yes, if adopted | New backend behind the phone tools | `App/PhoneAgent.swift`, `App/Controller.swift`, `App/Core/ToolCatalog.swift` | WDA backend unchanged and default |
| PocketAgent native | Yes, if adopted | New FFI exports and the `display_stream` feature | `Native/idevice.h`, `Native/idevice.patch`, `Scripts/bootstrap.py` | Same pinned idevice revision |
| Automation companion | No change in this phase | Remains the fallback | WDA runner | Removal only after parity |
| Looktech Android and iOS apps, Bluetooth and ISP firmware, schema, rpc, lt-vad | No | No glasses-device contract, protocol or audio algorithm change | None | None |

### Current design to target design

| Current module | Current responsibility | Relation | Change |
|---|---|---|---|
| `App/Controller.swift` device connection | RP tunnel, RSD handshake, DDI check and install, DVT runner launch and stop | Extend | Keep tunnel and DDI; own DDI service sessions and, if required, the stream; launch the runner only for the WDA backend |
| `App/PhoneAgent.swift` | WDA HTTP calls, snapshot and node mapping, effects | Extend | Move WDA calls unchanged behind a backend protocol; add the DDI backend |
| `App/Core/ToolCatalog.swift` | Phone tool specs | Keep | Same names and parameters; backend-specific capability text where semantics differ |
| `Native/idevice.h`, `Native/idevice.patch`, `Scripts/bootstrap.py` | FFI surface, local idevice patch, build features | Extend | Export HID, screen capture, pasteboard and display stream with long-lived handles; enable `display_stream` |
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
- System dialogs and paste permission prompts are reported as needing the user's action
  on the phone. Gap 2's root cause is open, and this design does not depend on it.
- If the hit test cannot name the foreground app, the observation says so instead of
  guessing.
- No new entitlement, stored secret or synchronized data. Pairing data stays local.

### Integration order

1. Run the experiment below; keep its material outside the repository and record only
   the condensed conclusion here.
2. Observation: export screen capture and add the AX reader. Neither depends on the
   stream question.
3. Introduce the backend protocol in the phone executor with WDA moved behind it
   unchanged.
4. Add the input exports (HID, pasteboard and, if required, the stream) and the DDI
   backend behind a local developer setting; compare it with WDA on the same pages.
5. Make DDI the default only after core tests, the iOS build, IPA inspection and the
   exact-device exercise pass.

### Discriminating experiment

On one phone, through PocketAgent's tunnel path rather than devicectl, and with no
Mac-side Device Hub or mirroring session open: send the same tap to a harmless target
without a display stream and then with one active, confirming each by screenshot. Then,
with a system alert on screen, record whether a tap lands, without attempting a
workaround. Record the iOS build, the mounted DDI build and the CoreDevice version for
every run: ipb's no-stream evidence is from beta 24A5430a with DDI 27A5252f, current
release builds are 24A437 (iOS 27.0) and 24A446 (iOS 27.0.1), and PocketAgent's own
download is 27A5228h. If the stream is required, also measure its setup time, whether a
screen-sharing indicator appears and its power cost.

### Verification boundary

- Established from sources and inspection only: the shared RSD path, the DDI contents,
  the idevice clients and the missing FFI exports. ipb's device records describe a
  Mac-hosted client, not PocketAgent on the phone.
- Not established: any DDI service call from PocketAgent; the stream requirement; Gap 2
  on this path; the AX dialect on iOS 27.0.1; latency, power and background behavior.
- Nothing was built, installed or sent to a phone for this document; the DDI was mounted
  read-only on a Mac for inspection.

</details>

## 4. Resources and delivery plan

| Module | Repository | Owner | Estimate | Branch | Release | Test date | Status / last checked | Depends on |
|---|---|---|---:|---|---|---|---|---|
| Discriminating experiment | PocketAgent, material kept local | TBD | TBD | TBD | None | None | Waiting for the user's authorization and phone choice; 2026-10-12 | One phone with Developer Mode and a DDI |
| Screen capture export and AX reader | PocketAgent native | TBD | TBD | TBD | TBD | TBD | Not started; 2026-10-12 | None |
| Backend boundary | PocketAgent app | TBD | TBD | TBD | TBD | TBD | Not started; 2026-10-12 | None |
| Input exports and DDI backend | PocketAgent app and native | TBD | TBD | TBD | TBD | TBD | Not started; 2026-10-12 | Experiment and the rows above |

Only the user can authorize the experiment and choose its phone. The remaining rows are
implementation work; assignment and schedule are not set.
