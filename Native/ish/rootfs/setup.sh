#!/bin/sh
# Runs inside the pinned i386 Alpine container; see Scripts/ish_runtime.py rootfs.
set -eu
printf '%s/main\n%s/community\n' "$POCKETAGENT_REPOSITORY" "$POCKETAGENT_REPOSITORY" > /etc/apk/repositories
# Every package of the closure is pinned (dependencies.json alpineRootfs.lock);
# a branch update that drops a pinned version fails here instead of drifting.
# shellcheck disable=SC2086
apk add --no-cache $POCKETAGENT_PACKAGES
rm -rf /var/cache/apk/*
# init only reaps orphans: no openrc services and no getty (the iSH kernel has no VT).
printf '::ctrlaltdel:/bin/true\n' > /etc/inittab
# Scripts run as uid/gid 501 (the iOS app's own uid, so hostfs ownership matches).
addgroup -g 501 pocket
adduser -D -u 501 -G pocket -h /home/pocket -s /bin/bash pocket
mkdir -p /workspace && chmod 755 /workspace
# Phone bridge launcher. The helper itself is written into each run by the app
# and only read by python3: nothing is executed from the project (hostfs) mount.
mkdir -p /usr/local/bin
printf '#!/bin/sh\n: "${POCKETAGENT_HELPER:?pocketagent-phone works only inside run_script}"\nexec python3 "$POCKETAGENT_HELPER" "$@"\n' \
    > /usr/local/bin/pocketagent-phone
chmod 755 /usr/local/bin/pocketagent-phone
# Scripts cannot regain privileges; the kernel also sets no_new_privs.
find / -xdev -perm -4000 -type f -exec chmod u-s {} + 2>/dev/null || true
find / -xdev -perm -2000 -type f -exec chmod g-s {} + 2>/dev/null || true
apk info -v | sort > /etc/pocketagent-packages
printf '%s\n' $POCKETAGENT_LOCK | sort > /tmp/expected-packages
if ! cmp -s /etc/pocketagent-packages /tmp/expected-packages; then
    echo "Installed packages differ from the lock:" >&2
    diff /tmp/expected-packages /etc/pocketagent-packages >&2 || true
    exit 1
fi
rm -f /tmp/expected-packages
