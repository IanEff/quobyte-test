#!/bin/bash
# quobyte-test — ntp.sh
# Installs and configures ntpd against Google's metadata-server NTP.
#
# Quobyte relies on the host's clock sync and alerts (server/no_ntp_detected)
# when it doesn't find it. Its install guide says `apt-get install ntp` on
# Ubuntu, so that's what this does rather than keeping the image's default
# chrony. On 24.04 `ntp` is a transitional package for ntpsec (daemon still
# `ntpd`), and it conflicts with chrony, so apt removes chrony.
#
# Idempotent. Runs from common.sh on every boot, and `task ntp` pipes this
# same file to the running VMs over IAP.
set -euo pipefail

echo "[ntp] Installing ntp"
if ! dpkg -s ntp >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y ntp
fi

# Only one daemon should discipline the clock.
systemctl disable --now systemd-timesyncd chrony 2>/dev/null || true

# GCE's metadata server is a leap-smeared source reachable from every VM
# with no egress. Mixing it with public (non-smeared) pool servers would
# make the clock disagree with itself around a leap second, so it's the only
# source.
CONF=/etc/ntpsec/ntp.conf
sed -i -E '/metadata\.google\.internal/! s/^(pool|server) /#&/' "${CONF}"
grep -q '^server metadata.google.internal' "${CONF}" \
    || echo 'server metadata.google.internal iburst prefer' >> "${CONF}"

systemctl enable ntpsec >/dev/null 2>&1
systemctl restart ntpsec

# Wait up to ~3 min for ntpd to select a peer (the '*' row in ntpq -p). It
# needs a few 64s polls, unlike chrony's near-instant iburst. Not fatal:
# ntpd keeps converging after this script returns.
for _ in $(seq 1 90); do
    if ntpq -pn 2>/dev/null | grep -q '^\*'; then
        echo "[ntp] Synced: $(ntpq -pn | awk '/^\*/ {print "peer " substr($1,2) ", offset " $9 " ms"}')"
        exit 0
    fi
    sleep 2
done
echo "[ntp] WARNING: ntpd has no selected peer after 3 min (still converging?)" >&2
ntpq -pn >&2 || true
