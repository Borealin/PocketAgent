# Voice input and Live

Implement two separate PRs in order. The base for voice input is the published
0.4.0 / 19.1.7 revision `7f09cef9e9bce4befcf936a9d092ec99a6ff9524`.
The original Duo worktree, version/feed, signing and device state are outside
this change.

## Phase 1: Local dictation

Click the microphone, stop, inspect a separate preview, then explicitly append
confirmed text to the original conversation's latest draft. Keyboard edits and
attachments survive; only the ordinary send/steer/next/remember controls can
submit or save that draft. Capture/finishing disable those submission buttons.
MVP appends at the end (with a newline when needed); selection-aware insertion
and press-and-hold gestures are deferred.

Use iOS 26 SpeechAnalyzer with SpeechTranscriber when hardware and the selected
locale support it. Otherwise try DictationTranscriber's own supported locales;
it is an on-device module, not SFSpeechRecognizer's server-backed fallback.
Prepare system-managed model assets before capture. Offer Mandarin and English,
display the actual matched locale, and explain keyboard/system-dictation
fallback when microphone access, assets or local recognition are unavailable.
No legacy Speech server authorization, cloud request or paid API is added.

Recognition is ephemeral. A session ID and generation reject stale starts and
results. Volatile text replaces the current guess; finalized audio ranges are
accepted once, preserving deliberately repeated words. Only explicit
confirmation writes through HistoryOwner, consumes the preview after success,
and increments the existing draft edit revision. A failed history write keeps
the latest draft and preview. A storage-failure notification stops audio and
retains finalized preview text while rejecting further recognition results.

Cancel, conversation replacement/switch/deletion, entering the background and
audio interruption/device route changes stop capture; microphone capture never resumes
automatically. Explicit cancel/session/background transitions discard the
unconfirmed preview. Other audio failures retain already finalized text. No
audio, recognition preview or credential enters history, logs, export or sync.
The bounded PCM stream holds eight owned buffers; overflow fails cleanly.
Capture stops after 60 seconds; finalization waits at most 10 seconds before
offering only already finalized text. Audio stays in memory and is never saved.
Temporary inactive scenes, such as the first microphone permission alert, do
not cancel a pending start or preview. Route-change reasons for adding/removing
devices stop capture; category/configuration changes from setup do not. Storage
errors do not create dictation notices when no generation exists. Successful
history identity changes provide the session cancellation boundary, so failed
clear/recovery transactions do not discard the preview in advance.

Implemented: pure preview/history append logic, native capture/controller,
composer controls, lifecycle integration and microphone purpose string. Three
Core tests pass for result revision/repetition, stale generation rejection, and
explicit latest-draft append with failed-write retention. The native controller
and pure input compile in Swift 6 strict concurrency against the installed iOS
SDK with an iOS 26 deployment target. These tests are not App/device evidence.
Independent review, complete App build/IPA inspection and remote CI are still
required; exact-device microphone/locale/assets/route/permission exercises have
not been run. No recording or device operation was authorized for this work.

## Phase 2: Live — pending

Start after Phase 1 review as a separate PR. Reuse only the small process-wide
microphone lease, permission and audio-session ownership boundary. Live's
network session, playback, barge-in and tool dispatch remain separate from
dictation preview/draft insertion. No Live backend, credential, transport or
automatic tool dispatch is prebuilt in Phase 1. Provider capability/credential
origin validation, frozen accepted-turn configuration and the serial phone
action queue remain required for that later work.

## API references and decisions

- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
  and [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber):
  runtime hardware/locale checks and a local fallback, rather than assuming all
  iOS 26 devices or system keyboard languages have the new model.
- [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory):
  system-managed assets/downloads; no bundled speech model or recording file.
- [Speech permission](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
  and [microphone permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)):
  new local modules require microphone access for capture, not legacy server
  recognition authorization.
- [start(inputSequence:)](https://developer.apple.com/documentation/speech/speechanalyzer/start(inputsequence:))
  returns immediately; [finalizeAndFinishThroughEndOfInput](https://developer.apple.com/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput())
  drains the ended input and final results. Cancellation uses cancelAndFinishNow.

Unknown until device exercise: model availability/download behavior on each
reference phone and OS, Mandarin/English mixed-term accuracy, Bluetooth routing,
and system-interruption behavior. No hardware list or quality claim is inferred
from the SDK build or previous PocketAgent device acceptance.
