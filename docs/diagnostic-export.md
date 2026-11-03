# Diagnostic export

Provide a user-initiated local ZIP for investigating execution problems without
requiring a USB connection or exposing the app's Documents directory.

## User flow

- Settings → 诊断 → 导出近期诊断包 includes recent existing opt-in run metadata
  and the global phone-connection metadata log.
- Long-press the assistant or a task in the conversation list → 导出诊断包
  includes only runs attributed to that conversation.
- Generate a snapshot off the main actor, then use native system sharing to save
  or send it. Regenerate explicitly to include events written afterward.
- An empty export still contains environment metadata and explains how to enable
  the existing logging option, restart and reproduce. Logging stays off by default.

## Privacy and scope

The exporter reads only `run-<UUID>.jsonl` and, for recent exports only,
`Application Support/Diagnostics/phone-connection.jsonl`. It does not read history,
providers, keys, pairing records, screenshots or native free-text logs.
Rebuild every event from closed event/field/value allowlists. Keep numeric timing,
counts, typed outcomes and known operation/error categories; discard arbitrary
strings, messages, URLs and identifiers. Archive names are sequential aliases.

The manifest includes generic app/build/system versions, phone/tablet family,
current backend, logging state, background-task namespace validity, and current
window dimensions/orientation/scale. Current environment is not historical state.
The run's first `run_context` event records local conversation attribution and
the frozen backend only when existing diagnostic logging is enabled. Export
removes that conversation identifier. Legacy logs remain available in recent
export; they cannot be safely assigned to a conversation retrospectively.

Discovery is nonrecursive and bounded at 2,048 directory entries. Filter by
conversation before selecting the newest 12 matching run files. Read at most
16 KiB per candidate for attribution, 512 KiB of each file's tail, and 4 MiB of
tail input in total. Reserve one tail for the standalone connection log in recent
exports. Omit incomplete or malformed records; report limits, skips and truncation.
Use no-follow directory/file opens and accept only regular log files.

ZIP uses the standard stored format with CRC32 through system zlib, adding no
dependency. A unique temporary directory is excluded from backup, mode 0700;
the archive is mode 0600 with iOS protection until first authentication. Retain
the file during sharing; OS temporary storage cleanup owns its eventual lifetime.
There is no upload, history format change, replay, or phone connection/action.

## Verification

Core regressions cover privacy with adversarial fields, scoped attribution and
bounded tails/discovery, and ZIP interoperability with the system unzip tool.
Delivery also requires existing host suites/privacy checks, iOS archive and IPA
inspection, plus device verification of generation and native sharing. Device
results do not establish that every reported execution failure can be diagnosed.
