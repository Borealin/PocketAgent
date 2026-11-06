# Duo dynamic control state

## Scope and current decision

Owner: PocketAgent Duo integration. Base: main `619347e`; PR #16 at `066f94c`
is the historical fixed-pane experiment, not the architecture baseline for this
replacement. The feature targets an App/window. A side is an observed result,
never a persisted action scope. Keep the accepted adaptive chat UI and independent
task-card work unchanged. Cloud relay, AgentKit replacement and general AX/HID
latency changes belong elsewhere.

Existing evidence establishes display UUID/active/orientation and typed
UUID-to-touchscreen association, but does not establish scene/App-to-global-region
mapping. A native window frame and PID can remain unchanged after pane exchange.
A gutter, equal widths, `primary`, frontmost PID and context ID cannot prove pane
ownership. Do not admit inner-screen actions on those guesses.

## Implementation sequence

1. Add bounded read-only display-state parsing and reporting. Recognize active,
   rotated, ambiguous and unsupported topology without a device/OS allowlist.
   Keep the currently verified ordinary single-primary portrait AX/HID path.
   Report multi-display/window ownership as unavailable until proven.
2. Bind observations, screenshots and physical-action boundaries to a fresh
   display identity/geometry state (UUID when advertised). Changes invalidate old points/nodes/images.
   Never migrate an in-flight contact; release on its original channel, preserve
   unknown effects and require fresh observation/new turn as existing gates demand.
3. Reuse only verified descriptor association from #16; no fixed crop, synthetic
   app identity, permanent left/right picker or guessed split-management gesture.
   Unknown topology must return useful state and a refusal before effects.
4. Review design and retained changes with real Claude Opus 5.5. Resolve findings
   against owning source; keep model/results outside Git.

The first Opus decision supports an anonymous optional status in the existing
failure envelope and explicitly calls this a guard milestone, not Duo support.
Its suggested <=10 Hz stop-only polling remains unmeasured. The retained design
samples before/after actions, releasing input before the post-check rather than
delaying release with a layout RPC. Live mid-contact detection remains open;
no notification service or concurrent polling mechanism is added speculatively.
The simulator protocol probe still returns null scene binding/target region/touch
transform, including open/closed states. Open and partially open can share display
metadata; fingerprint equality is not proof of unchanged posture or window layout.

## Verification and expansion boundary

Use 1–3 focused observable regression contracts: strict topology admission,
observation invalidation across same-size display changes, and refusal/release
without replay across a transition. Run existing Core/native checks, iOS build
and IPA inspection. A dedicated simulator may validate geometry/classification;
it cannot validate on-phone DDI transport. No connected physical device actions
or model phone turns are authorized in this stage.

Before expanding supported states, obtain revision-bound display UUID and HID
association, global window/scene region and target ownership, rotation/capture
mapping, per-point owner/overlay exclusion, shared-keyboard policy, and transition
release evidence for each admitted state. Active detection is separate from
actively arranging split view or moving/opening Apps in a pane; the latter stays
unavailable until a real protocol and independent outcome are established.
