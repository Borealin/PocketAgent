# PocketAgent

Native Swift iOS 26+ multi-session phone assistant with AgentKit and an idevice/WDA backend.

- Read docs/engineering.md before source changes; keep it current.
- No API keys, pairing records, local endpoints, Apple teams/certificates, device IDs,
  transcripts, screenshots, provisioning profiles or success-only evidence in Git.
- Secrets stay in local Keychain; pairing data stays local and excluded from backup/sync.
- One atomic local history file; migrations preserve IDs and real messages.
- Never replay interrupted phone actions. Keep event order and call/result adjacency.
- One serial phone action queue. Freeze provider/model/credential when a turn is queued.
- Sync only explicit portable data, preserve conflicts, and retain deletion tombstones.
- Build scripts use environment/ignored local config for signing; no personal defaults.
- Core tests, iOS build, IPA inspection and exact-device exercise are delivery gates.
- Evidence belongs outside this repo; docs contain design and condensed confirmed fixes.
- Writers use assigned ownership and must not overwrite concurrent work.
