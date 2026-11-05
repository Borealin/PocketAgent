# Duo adaptation

The user approved delivering the accepted Duo UI, real simulator builds and
anonymous geometry diagnostic separately from automatic task-card collapse.
The original default-collapse/transient-expansion contract and its
portrait/landscape phone-turn matrix remain follow-up work in
[#12](https://github.com/Borealin/PocketAgent/issues/12), outside this delivery.

The UI uses one system `NavigationSplitView` for the session list and
conversation. Retain its default sizing/style: removing the maximum sidebar
width restored an even division in the previously observed simulator pose with
an active vertical fold; this is not a guarantee of equal columns in every pose.
Candidate 19.1.7's current inner-display landscape layout was accepted, and
manual new-session/return navigation restored the original session and draft,
including its visible composer text. Returning to the outer portrait display
preserved the selected session and the persisted/visible draft, with input and
send controls inside the window. Existing session IDs/order, messages and attachments remained
exact; the known validation draft was safely cleared, with no active turn.
Active-division alignment and the full system Split View matrix remain unaccepted.
Conversation, model and draft remain owned by
`ChatController` across layout changes. Existing native forms and sheets keep
their safe-area handling. Compact vertical size classes display at most
three draft lines (the full draft remains scrollable); other layouts retain six.
Both landscape orientations are enabled without changing the iOS 26 minimum.

The current system indicator is owned by `BGContinuedProcessingTask`, not a
custom ActivityKit extension. The Xcode 27.2 public API exposes title, subtitle,
progress and completion, but no presentation/collapse timer. Shorter titles or
less frequent updates alone cannot establish an obstruction fix. Establish the
captured geometry and preparation eligibility before changing the current gesture.
Do not replace continued execution with a shorter background allowance, fake progress, replay
phone effects or inject unverified gestures on a newly inferred Duo layout.

The horizontal preparation gesture's implementation is unchanged, but the
turn's `PhoneExecutor` captures its geometry only once at creation. Capture
requires a foreground key window with phone idiom, portrait interface
orientation, screen width less than height, and a top safe inset of at least
59 points. A turn created in landscape captures no geometry and skips the
gesture for the entire turn, even after the target returns to portrait; there
is no resampling. With captured geometry, preparation still requires an exact
match between the observed frame and the stored bounds, alongside its existing
foreground and effect guards. Which Duo inner-display poses satisfy those
conditions remains untested.

Existing opt-in run logging records one anonymous `phone_task_surface_geometry`
event at executor creation, including capture eligibility and rejection reason.
It changes no guard or gesture and is excluded from the diagnostic ZIP allowlist.

Both native build scripts now accept `--sdk iphonesimulator`; `iphoneos` remains
the default. The generated project selects `.build/native-iphonesimulator` and
`.build/ish/Release-iphonesimulator` for simulator linking, leaving device
products separate. Libarchive's bzip2 dependency is explicitly linked after its
compression symbols failed the first simulator Debug link. These are actual
pinned native libraries, without repackaging device binaries or substituting
successful phone/script implementations. Build them with:

```sh
python3 Scripts/bootstrap.py --native-only --sdk iphonesimulator
python3 Scripts/ish_runtime.py build --sdk iphonesimulator
xcodegen generate
xcodebuild -project PocketAgent.xcodeproj -scheme PocketAgent \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DuoSimulator build CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

Screenshots and logs stay outside Git. Simulator layout checks do not establish
DDI/WDA control of a second app, hardware transitions or a signed physical Duo
installation.

PocketAgent's DDI adapter currently accepts only a single portrait primary display and rejects rotated
display geometry independently of the app's UI orientation support. Pane
ownership, rotated touch mapping and multi-display targeting require verified
device metadata before relaxing that refusal. Preserve the existing
fresh-observation, serial-action and no-replay contracts.

## Fixed Split View control investigation (2026-11-05)

A separate Mac-side ipb/CoreDevice probe exercised a physical Duo on iOS 27.3
with DDI 27B52 and CoreDevice 651.32. PocketAgent 0.4.0 (20.1.2) was the retained
conversation UI; its own executor was not the probe's controller. No app binary
or production DDI guard was changed, and no XCTest/WDA runner was started by
the probe. These observations do not establish on-phone executor acceptance.

The expanded device continued to mark the inactive outer display as `primary`.
Default screenshots returned that display's black image. Explicit inner-display
capture worked, and HID descriptors exposed a separate touchscreen bound to
that display. Selecting its descriptor and applying the measured
`landscapeRight` device-orientation mapping produced the intended inner-screen
tap; using the display's `rot90` content orientation instead did not. Service
selection must follow live display metadata, rather than a fixed main-touchscreen
ID or the first descriptor.

The Home Screen app menu's Open in Split View action exposed an empty second
pane. Standard app activation placed PocketAgent there beside Settings. Explicit
PID reads returned each app's AX content. The right-hand app's child frames were
relative to its own window; they omitted its offset in the full inner-display
screenshot. The application root still reported portrait display dimensions.
Neither the root frame nor an unadjusted child frame establishes pane ownership.

A target-side Settings search tap and physical keyboard usage reached that
search field while PocketAgent's existing draft remained exact. The software
keyboard spanned both panes. Clipboard Unicode input produced a system paste
prompt, but no exact target-field insertion was verified; a DDI tap at the prompt
was followed by search dismissal, and the later prompt disappeared without a
confirmed insertion. Do not treat sender success as text acceptance or replay
the paste automatically.

With both panes occupied and Settings' search field still focused on the left,
standard activation of Calculator replaced PocketAgent on the right. Restoring
PocketAgent preserved its draft. Keyboard focus therefore did not select the
activation destination in this observed arrangement; arbitrary app launch into
the intended pane remains unresolved.

The user directed further command/protocol exploration to ipbtools using a Duo
simulator before any more physical-device probing: app-side swapping, per-pane
Home and app launch, then touch and content capture. Simulator results must
identify their actual backend and remain separate from physical DDI acceptance.
Raw screenshots, AX trees and local probes remain outside Git.

Closed-outer-display portrait exercise of candidate 19.1.7 identifies the
capture failure: the foreground phone window is portrait, but its safe insets
are top 0/right 84 points, so the existing top-inset guard captures no geometry.
The expanded task card covers Clock's title/navigation area. An external manual
status-band horizontal probe at 4% of screen height did not collapse it; the
candidate app's guard skipped its own preparation gesture. Two controlled external
central upward swipes collapsed the card while the task continued; these manual
probes do not establish a candidate-app repair. The effective swipe starts below the native
top-5% band and would start on underlying app content after the card collapses,
so it cannot be added as unconditional action preparation.

The observed explicit-PID native snapshot can read `ActivityProgressUI`, but
lacks verified app/task ownership and a screen mapping for its host frames.
Visibility flags and a generic phase title cannot establish that this task's
expanded card covers the swipe start. Safe automatic collapse remains blocked.
The requested default-collapse/transient-expansion contract is unimplemented;
the public task API supplies no
presentation timer. An isolated iOS 27.2 simulator probe fails with
`BGTaskSchedulerErrorDomain` code 1:
`BGTaskScheduler is not available on this platform.` The separate task-card
follow-up must exercise portrait-created and landscape-created turns, including a
landscape-created turn whose target subsequently returns to portrait.
The full system Split View resizing matrix, remaining secondary screens and
inner-display DDI/WDA control remain unaccepted. Rotatable UI alone does not establish
phone-control acceptance. Revision-bound validation results and success
artifacts are kept in the PR description and external evidence.

References: [Apple's adaptive-layout guidance](https://developer.apple.com/videos/play/tech-talks/111463/),
[Duo preparation](https://developer.apple.com/iphone-duo/prepare/), and
[continued-task title API](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask/updatetitle(_:subtitle:)).
