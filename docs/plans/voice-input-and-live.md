# Voice input and Live

Implement local dictation in PR 14, then Live in a separate PR. The dictation
base is published 0.4.0 / 19.1.7 at
`7f09cef9e9bce4befcf936a9d092ec99a6ff9524`. The first complete implementation
baseline remains `166a77e` (513 handwritten non-test changed lines). Original
Duo worktree, feed/version, signing and device state are outside this change.

## Phase 1: Local dictation

Tap the microphone in the input row to dismiss the keyboard and start. Tap its
stop icon to finish; finalized text automatically appends once to the original
conversation's latest editable draft. Existing keyboard text and attachments
survive. Sending, steering, next requests and memory saving still require their
ordinary manual controls. Preparing/finishing use a small spinner; the send
position becomes Cancel while input is busy. Cancel and switching conversation
invalidate the generation and append nothing. Language selection lives in
Settings, persisted in one local UserDefaults preference.

During preparation, recording and finishing, the existing input bubble becomes
read-only. It renders the current draft plus finalized speech and secondary
volatile text, bounded to the composer's line allowance with recent text visible.
Only presentation changes: partial results never enter the editable binding or
HistoryOwner. Cancel restores the original draft display; Stop still uses the
same onFinal transaction once. A native waveform symbol animates only during
recording and stays static with Reduce Motion. It is a recording indicator, not
an audio-level meter. Stop is red with a 44-point target at the microphone's
position; preparation/finishing retain short status and spinner feedback.

Recognition remains separate from the draft while recording. Audio-range
revisions replace volatile guesses, preserving deliberately repeated final
words. The existing ready phase is internal: a duplicate ready transition is
rejected, so timeout and late finalization cannot dispatch two automatic
appends. The onFinal callback uses the existing HistoryOwner append transaction
and draft edit revision; no new draft writer, delivery ledger or history format
is introduced. Success consumes the input. Only a write failure exposes
copyable finalized text with Retry and Discard. Empty recognition returns to
idle with a short notice. Interruption appends only already recognized final
text and reports that the remainder was not retained.

Use iOS 26 SpeechAnalyzer with runtime hardware/locale/asset checks. Prefer
SpeechTranscriber, then DictationTranscriber's on-device supported locale.
Prepare system-managed assets and obtain microphone permission before capture;
fail explicitly to keyboard/system dictation when unavailable. Permission-alert
inactive scenes preserve preparation. Entering the background cancels only
preparation or active capture; explicitly stopped input may finish within the
existing 10-second limit and append to its original session. Failed-write text
also survives backgrounding. There is no new background task or automatic mic
resumption. Audio device addition/removal, interruption and media-services loss
stop capture; setup category/configuration changes do not.

PCM stays in an eight-buffer bounded memory stream; overflow fails cleanly.
Capture ends after 60 seconds. Audio and temporary recognition are never saved,
logged, exported or synchronized. Only draft text is written locally; ordinary
message sync applies after the user explicitly sends it.

The independent preview/confirmation interaction was rejected by the user.
Tap-toggle avoids first-use permission/model preparation breaking a held
finger gesture; press-and-hold is deferred. Streaming revisions directly into
the draft would complicate concurrent typing and persistence, so only completed
input is appended. No caret/selection infrastructure or microphone long-press
menu is added.

Validation: three Core regressions pass, including the duplicate-ready guard;
strict Swift 6 concurrency typechecking passes with an iOS 26 deployment target.
Full App/IPA/CI checks must be repeated for this UI change. The user confirmed
20.1.3 directly appended to the draft without another confirmation. That covers
the earlier static composer, not this streaming display/recording animation.
The observed text alone does not establish the number of recording turns or
prove single-turn deduplication. No new device exercise is claimed. Route,
asset-download, permission, background finishing and storage-retry scenarios
still need exact-device exercise. Logs/artifacts remain outside Git.

## Phase 2: Live

Implemented as a separate stacked change over the reviewed local-dictation
head `70aaa818208f965bbf9f905490a1c064a3f7b3e9`. The Live baseline remains
`429a775` (914 handwritten non-test changed lines); rebasing does not reset it. One native WebSocket
connects to GPT-Live (`gpt-live-1`), with client delegation and explicit
`store: false`. Start freezes the selected provider, full HTTPS Live endpoint,
local key and background choice. HTTPS is changed to WSS only after checking
the provider's existing local credential-origin binding. No automatic provider,
model, endpoint, protocol or credential fallback exists. The local optional
ProviderFile setting remains version 1 and is excluded from portable sync;
provider sync preserves it without granting a new key origin.
The Start UI explains that audio, captions and selected phone-task results go
to this Live provider for conversation/playback, which can differ from the task
model's provider. Displayed pricing is the OpenAI standard reference; gateways
use their provider's actual rates.

Live shares only MicrophoneOwnership with dictation. One voiceChat audio engine
with VoiceProcessing captures and plays mono PCM16LE at 24 kHz. The audio tap
and single WebSocket writer each hold at most 96 chunks/packets. With the
requested 1,024-frame tap at a 48 kHz hardware rate, each nominal capture chunk
covers about 21 ms, so each queue can accommodate roughly two seconds of
normal scheduling/network jitter. Actual callback sizes/rates and network
behavior remain unmeasured; this is not a timing guarantee. Playback has a
60-second PCM memory ceiling (about 5.8 MB as Float), not a target latency or
an assumption that the server paces output in real time. Overflow still fails
cleanly. Audio packets bypass published logical state, and playback status only
publishes Boolean changes; packet delivery no longer redraws the chat UI.
Protocol/capacity failures retain their own sanitized cause instead of being
reported as connection failures. Audio is uploaded
only after session.started. Muting immediately invalidates old captured and
unsent mic packets before queuing the server control; an already submitted
network frame cannot be retracted. The mic mute retains the audio session and
billing; End stops local audio immediately, sends session.close and drains up
to fifteen seconds for session.closed. No final event means final usage is
unconfirmed. Usage snapshots replace, never sum. There is no automatic
reconnect, retry or phone-action replay. Protocol/provider error prose and raw
JSON/audio/transcripts are not logged.

Input/output captions are continuous, transient and bounded. There is no
utterance-complete event. A client delegation creates one editable task card,
not an action. Later captions never silently alter the card. An unaccepted card remains
copyable after an error/end, with acceptance disabled; a new session never
automatically adopts or submits it. Confirm sends
only its visible text, once, to the original conversation through the existing
history/freeze/queue path with consumeDraft=false: keyboard text, photos and
reference chips survive. The primary line queues a next request when busy;
Live never implicitly steers or rewrites the running task. A busy independent
task refuses this confirmation and points to the ordinary chat's explicit
steering control. Memory-like requests are refused in Live and use the existing
memory confirmation entry. No second history writer or voice ledger exists.
Accepted tasks and AgentKit results keep their original durable messages;
spoken paraphrases are not appended as extra assistant messages.

An explicit, default-off option allows a user-started call to continue after
switching apps. Only an already started call may retain real playAndRecord
capture/playback under the audio background mode; preparing/connecting calls
are invalidated in the background regardless of that option. Inactive permission
alerts do not terminate preparation. Without the option, background ends Live.
Audio interruption, device route changes and media reset end audio without
automatic recovery. There is no silent playback loop or background keepalive
workaround. End voice and Stop phone execution remain separate controls; the
latter uses the existing runtime cancellation and terminal drain. Task-complete
or stopped speech is sent only after the host's terminal event.

Three Core regressions pass for origin/start admission, one-shot confirmed
tasks with draft/photo retention, and mute/close/late-event/usage behavior.
The native controller and view pass Swift 6 complete-concurrency typechecking
with an iOS 26 target and thin external host stubs; that is not whole-App proof.
Full App build, IPA inspection and independent review belong to the integrator. No real Live API,
key, recording or device was used for implementation. Account entitlement,
network handshake, acoustic echo cancellation, natural barge-in, Bluetooth,
background/lock-screen continuity, audio/task coexistence and final billing
remain exact-account/device acceptance gates. Natural interruption is model
behavior, not a deterministic local VAD guarantee; End voice is the immediate
local playback-stop control.

## References

- [Native symbol effects](https://developer.apple.com/documentation/swiftui/view/symboleffect(_:options:isactive:))
  and the Reduce Motion environment provide the recording indicator without
  timers, measured levels or an animation lifecycle.
- [GPT-Live primary WebSocket](https://developers.openai.com/api/reference/resources/live/primary-websocket)
  and [Live session lifecycle](https://developers.openai.com/api/docs/guides/live-conversations):
  continuous captions and cumulative usage without Realtime VAD/commit events.

- [ChatGPT dictation](https://learn.chatgpt.com/docs/prompting#use-voice-dictation)
  documents editable composer text before sending; it does not establish every
  mobile button detail. [Claude mobile dictation](https://support.claude.com/en/articles/10065434-use-dictation-on-claude-mobile)
  documents microphone input, manual sending and Settings language selection.
  These support a draft-input flow, not a second normal confirmation surface.
- [Apple dictation](https://support.apple.com/guide/iphone/dictate-text-iph2c0651d2/ios),
  [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber),
  [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)
  and [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
  distinguish ordinary text input from runtime model/device availability.
- [Speech permission](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
  and [microphone permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)):
  local modules need microphone access, not legacy server-recognition permission.
- [start(inputSequence:)](https://developer.apple.com/documentation/speech/speechanalyzer/start(inputsequence:))
  returns immediately; [finalization](https://developer.apple.com/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput())
  drains input and final results before the automatic draft append.
