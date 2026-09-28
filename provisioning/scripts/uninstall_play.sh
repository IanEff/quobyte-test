#!/bin/bash
# quobyte-test — uninstall_play.sh
#
# Removes the play clients. The `lake` bucket has to be unpublished first:
# Quobyte refuses to erase a volume that's still published over S3, so
# deleting the namespace alone leaves that PV stuck in Released with
# VolumeFailedDelete ("ENTITY_IN_USE ... delete all buckets first").
set -euo pipefail

KCTL_CONTEXT="${CLUSTER_NAME:-quobyte-test}"
NAMESPACE="quobyte"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

kctl() { kubectl --context="${KCTL_CONTEXT}" "$@"; }
# shellcheck source=provisioning/scripts/tunnel_lib.sh
source "${REPO_ROOT}/provisioning/scripts/tunnel_lib.sh"
# shellcheck source=provisioning/scripts/qmgmt_lib.sh
source "${REPO_ROOT}/provisioning/scripts/qmgmt_lib.sh"

# `volume unpublish` takes the volume handle, not the bucket name its -h
# advertises.
LAKE_VOLUME=$(qm bucket list 2>/dev/null | awk '$1 == "lake" {print $2}')
if [ -n "${LAKE_VOLUME}" ]; then
    echo "[play] Unpublishing bucket lake from ${LAKE_VOLUME}"
    qm volume unpublish "My Tenant/${LAKE_VOLUME}"
fi

echo "[play] Deleting namespace quobyte-play (PVCs -> Quobyte volumes)"
kctl delete namespace quobyte-play --ignore-not-found --wait
