# Duo adaptation

The requested outcome is usable PocketAgent UI on the Duo simulator, including
the outer display, open inner display, rotation, Split View and the keyboard,
plus a task indicator that does not continually cover the target app. The source
baseline is `85b8272`; this work is on `codex/duo-adaptation`.

The UI uses one system `NavigationSplitView` for the session list and
conversation. Retain its default sizing/style: a maximum sidebar width prevented
the system from aligning the two columns with the active vertical fold; removing
it restores the even division. The selected conversation, model and full draft
survive the checked window/posture changes. Existing native forms and sheets
keep their safe-area handling. Compact vertical size classes display at most
three draft lines (the full draft remains scrollable); other layouts retain six.
Both landscape orientations are enabled without changing the iOS 26 minimum.

The current system indicator is owned by `BGContinuedProcessingTask`, not a
custom ActivityKit extension. The Xcode 27.2 public API exposes title, subtitle,
progress and completion, but no presentation/collapse timer. Shorter titles or
less frequent updates alone cannot establish an obstruction fix. Reproduce its
presentation before changing the current preparation gesture. Do not replace
continued execution with a shorter background allowance, fake progress, replay
phone effects or inject unverified gestures on a newly inferred Duo layout.

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

DDI currently accepts only a single portrait primary display. Pane ownership,
rotated touch mapping and multi-display targeting require verified device
metadata before relaxing that refusal. Preserve the existing fresh-observation,
serial-action and no-replay contracts while assessing this boundary.

Current validation: 439 Core tests and 29 Distribution tests passed; the actual
app builds and starts on the iOS 27.2 Duo simulator, and the iOS Release archive
build and ad-hoc IPA signature/privacy inspection pass. The validation package
retains the current version/build; it is not a published release or a signed
physical-device acceptance artifact. Inspected outer portrait/landscape, inner layouts in both axes,
book/tabletop half-fold layouts, software keyboard avoidance, retained full
draft/model/session, Settings/provider forms and model/project pickers. The
full system Split View resizing matrix and remaining secondary screens are
still unaccepted; these checks used a nonsecret, non-networked layout fixture.

The reported system indicator obstruction remains open. An isolated task probe
on this simulator fails with `BGTaskSchedulerErrorDomain` code 1:
`BGTaskScheduler is not available on this platform.` Thus neither background
turn execution nor the requested default-collapse/transient-expansion behavior
can be accepted here. The existing gesture is unchanged. A connected, unlocked
physical Duo is the next prerequisite; no physical phone was operated during
this UI work.

References: [Apple's adaptive-layout guidance](https://developer.apple.com/videos/play/tech-talks/111463/),
[Duo preparation](https://developer.apple.com/iphone-duo/prepare/), and
[continued-task title API](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask/updatetitle(_:subtitle:)).
