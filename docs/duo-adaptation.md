# Duo adaptation

The requested outcome is usable PocketAgent UI on the Duo simulator, including
the outer display, open inner display, rotation, Split View and the keyboard,
plus a task indicator that does not continually cover the target app.

The UI uses one system `NavigationSplitView` for the session list and
conversation. Retain its default sizing/style: a maximum sidebar width prevented
the system from aligning the two columns with the active vertical fold; removing
it restores the even division. Conversation, model and draft remain owned by
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

At executor creation, existing opt-in run logging records one
`phone_task_surface_geometry` event: UIKit idiom/orientation enum values,
foreground-key-window presence, window/screen dimensions, top/right safe insets,
and capture outcome with the first rejection reason in guard order. It records
no window/scene identifiers or content and changes no admission or gesture.
This event is excluded from the current diagnostic ZIP allowlist; inspect the
local run log for this diagnostic. It cannot explain later preparation guards.

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

Physical acceptance of candidate 0.4.0 (19.1.6) confirms system task-card
obstruction on the closed outer display in portrait: the expanded card covers
Clock's title/navigation area through the wait phase and disappears after task
completion. The matching run records neither a native `surface_drag` call nor a
completed `phone_task_surface_gesture`; these records do not identify a specific
failed eligibility check. Repair remains required, and the requested
default-collapse/transient-expansion behavior is unimplemented. An isolated
iOS 27.2 simulator probe fails with `BGTaskSchedulerErrorDomain` code 1:
`BGTaskScheduler is not available on this platform.` Physical acceptance must
include portrait-created and landscape-created turns, including a
landscape-created turn whose target subsequently returns to portrait.
The full system Split View resizing matrix, remaining secondary screens and
Duo DDI/WDA control remain unaccepted. Rotatable UI alone does not establish
phone-control acceptance. Revision-bound validation results and success
artifacts are kept in the PR description and external evidence.

References: [Apple's adaptive-layout guidance](https://developer.apple.com/videos/play/tech-talks/111463/),
[Duo preparation](https://developer.apple.com/iphone-duo/prepare/), and
[continued-task title API](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask/updatetitle(_:subtitle:)).
