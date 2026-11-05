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

## Phase 2: Live — separate PR

Reuse the small process-wide microphone lease; keep Live transport, playback,
barge-in and tool dispatch separate from dictation. This dictation branch adds
no Live backend, credential or automatic tool dispatch. The later PR must retain
provider-origin validation, frozen accepted-turn configuration, explicit task
confirmation and the serial phone action queue.

## References

- [Native symbol effects](https://developer.apple.com/documentation/swiftui/view/symboleffect(_:options:isactive:))
  and the Reduce Motion environment provide the recording indicator without
  timers, measured levels or an animation lifecycle.
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
