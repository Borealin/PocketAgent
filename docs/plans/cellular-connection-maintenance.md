# Cellular connection maintenance

User request: detect cellular use, retry the phone connection while idle, offer
an in-app floating recovery reminder after sustained failure, and retain a
working connection across turns.

Use Model's existing RP connection ownership and serial connection gate. Retry
only RP setup or a read-only RSD directory check; never start control services,
mount an image or replay a phone action in maintenance. Three consecutive
failures show a dismissible reminder to temporarily disable cellular data and
keep LocalDevVPN connected. Continue recovery attempts while data is off; reset
the failure streak after success. Delays are 2, 5, 10, then 30 seconds; healthy
idle connections get a read-only check every 20 seconds.

Remove the foreground 120-second lease. A successfully checked RP connection
can be borrowed by a turn and retained again only after confirmed DDI/runner
cleanup. Stop, explicit release, local configuration changes and background
expiration invalidate retained handles. Explicit release/Stop pause maintenance
until the next foreground entry or explicit preparation. A local setting can
disable maintenance. Every borrowed connection is checked before phone setup;
a failed check fails that request without replay.

Foreground maintenance is continuous. The existing finite UIKit background
assertion covers a temporary trip to Settings; it is ended on foreground return
and cannot guarantee survival after suspension, termination or locking. Recovery
reminders are inside PocketAgent; iOS provides no arbitrary cross-app overlay.
Direct cellular bootstrap can still fail at the existing local TCP policy.

Validation: three Core regressions for backoff/reminder episodes, data-off
recovery eligibility, and idle/foreground/pairing/consent gates; full Core tests,
iOS Release archive and clean IPA inspection. Exact-device acceptance requires
cellular-only cold launch with USB physically removed, temporary-data-off
recovery, restored-data cross-turn reuse and transport-loss recovery. Host
checks do not establish these device behaviors.

Physical-device checks are pending; no device operation was performed for this
change. Host results belong to the reviewed branch revision and its PR.
