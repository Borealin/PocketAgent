# Duo adaptation

## Dynamic control state (work in progress)

The current [dynamic-state plan](plans/duo-dynamic-state.md) supersedes the
fixed left/right control direction in Draft PR #16. It adds native read-only
display evidence and refusal/invalidation boundaries, not inner-display control.
There is no persistent side picker, fixed crop or synthetic pane App identity
in this implementation. The accepted chat layout below is unchanged.

Every observation binds the advertised display UUID and active state, primary
state, rotation, scale and geometry. The established single-entry path retains
optional UUID/active metadata; explicit inactivity or malformed values refuse. A same-size display replacement invalidates the native
observation and hit-point cache. Coordinate/AX actions consume that binding; text chords retain the existing
focus sequence after its focus tap consumes a snapshot. Captures check against
the observation after reading. The existing single primary, not-explicitly-inactive, unrotated portrait
display path retains its App identity and AX point-ownership checks. Multiple
enumerated displays, inactive/ambiguous displays, unknown metadata and unverified
rotations refuse effects, including global Home, activation and clipboard writes.
When finalization encounters an unverified/changed layout it skips activation
rather than choosing a pane. Fresh observation can recover after a supported
layout returns; no previous action is replayed.

Unavailable-state reports include anonymous display counts, rotation and a
reason. The optional touchscreen descriptor probe reports a unique typed
display-UUID association, ambiguity or probe failure; it cannot authorize a
coordinate transform or an App/window target. UUIDs/service identifiers stay
native, out of model results. Successful observations receive no diagnostic
surface payload. No model tool can select a display.

Action completion samples the display after original-channel input release and
within the original deadline. A changed/unreadable state preserves an issued
effect as unknown and disables further input under the existing contract.
This is boundary sampling: there is no verified live update subscription or
mid-contact detection/atomicity guarantee. A layout change and return between
samples can be missed. Protocol-side simulator evidence also shows identical
display metadata for visibly open and partially open poses; a metadata fingerprint
is not a full posture, window-layout or continuous-generation identifier. Adding unmeasured getdisplayinfo RPCs to every HID packet
would extend gestures; it is not adopted as a real-time transition mechanism.

The remaining hard dependency is a fresh scene/App-to-global-window-region
mapping across exchange/resizing. Research observed unchanged PID and local AX
window frame after an App moved to the other pane. Display identity, primary,
frontmost, equal widths, context IDs and screenshot gutters do not establish that
mapping. Shared keyboards/system overlays and all inner-screen rotation/touch
transforms still require evidence. Existing calibrated Mac-side PR #16 touch,
crop and Home probes remain research inputs; they are not on-phone acceptance.
The first milestone can refuse every Duo pose if both displays remain enumerated.
It must not be presented as completed Duo automatic adaptation. System split
creation/resizing or pane-targeted launch remains unavailable pending protocol
and independent outcome evidence. No physical device or model phone turn was
operated for this milestone.

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

DDI currently accepts only a single portrait primary display and rejects rotated
display geometry independently of the app's UI orientation support. Pane
ownership, rotated touch mapping and multi-display targeting require verified
device metadata before relaxing that refusal. Preserve the existing
fresh-observation, serial-action and no-replay contracts.

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
