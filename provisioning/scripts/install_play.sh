#!/bin/bash
# quobyte-test — install_play.sh
#
# Deploys the play clients in quobyte/play/ (namespace quobyte-play):
#   trainer + evaluator  checkpoint write/verify across nodes (RWX consistency)
#   crossproto           same bytes through the CSI mount and the S3 gateway
#   metastorm            small-file metadata churn
#   datagen              one-shot fake home volume for File Query Engine / MCP
# plus an S3 access key for root (Secret s3-credentials) and the `lake`
# volume published as S3 bucket `lake`. Opens its own IAP tunnel if
# `task tunnel` isn't running (tunnel_lib.sh).
#
# Idempotent: the access key is only minted when the Secret is missing, the
# bucket is only published when it isn't listed yet.
set -euo pipefail

KCTL_CONTEXT="${CLUSTER_NAME:-quobyte-test}"
NAMESPACE="quobyte"
PLAY_NS="quobyte-play"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

kctl() { kubectl --context="${KCTL_CONTEXT}" "$@"; }
# shellcheck source=provisioning/scripts/tunnel_lib.sh
source "${REPO_ROOT}/provisioning/scripts/tunnel_lib.sh"
# shellcheck source=provisioning/scripts/qmgmt_lib.sh
source "${REPO_ROOT}/provisioning/scripts/qmgmt_lib.sh"

kctl apply -f quobyte/play/namespace.yaml

if kctl -n "${PLAY_NS}" get secret s3-credentials >/dev/null 2>&1; then
    echo "[play] s3-credentials Secret exists — keeping the current access key"
else
    echo "[play] Minting a GENERAL_ACCESS_KEY for root"
    # `--output json` is ignored here; create always prints
    #   id    : <key id>
    #   secret: <secret>
    out=$(qm accesskey create --tenant="My Tenant" GENERAL_ACCESS_KEY root 2>/dev/null)
    key_id=$(awk '$1 == "id" && $2 == ":" {print $3}' <<<"${out}")
    secret=$(awk '$1 == "secret:" {print $2}' <<<"${out}")
    if [ -z "${key_id}" ] || [ -z "${secret}" ]; then
        echo "[play] ERROR: couldn't parse accesskey output:" >&2
        echo "${out}" >&2
        exit 1
    fi
    kctl -n "${PLAY_NS}" create secret generic s3-credentials \
        --from-literal=AWS_ACCESS_KEY_ID="${key_id}" \
        --from-literal=AWS_SECRET_ACCESS_KEY="${secret}"
    echo "[play]   access key ${key_id} stored in ${PLAY_NS}/s3-credentials"
fi

echo "[play] Applying quobyte/play"
kctl -n "${PLAY_NS}" delete job datagen --ignore-not-found
kctl apply -k quobyte/play

echo "[play] Waiting for PVCs to bind"
kctl -n "${PLAY_NS}" wait pvc --all --for=jsonpath='{.status.phase}'=Bound --timeout=180s

# CSI volumes are named after their PV, so the lake PVC's volume is its
# volumeName.
LAKE_VOLUME=$(kctl -n "${PLAY_NS}" get pvc lake -o jsonpath='{.spec.volumeName}')
# A published volume can't be erased ("still published via the S3 interface
# - delete all buckets first"), so a bucket left on a previous lake volume
# both blocks that PV's deletion and squats the name. Move it if so.
PUBLISHED_ON=$(qm bucket list 2>/dev/null | awk '$1 == "lake" {print $2}')
if [ "${PUBLISHED_ON}" = "${LAKE_VOLUME}" ]; then
    echo "[play] Bucket lake already published on ${LAKE_VOLUME}"
else
    if [ -n "${PUBLISHED_ON}" ]; then
        echo "[play] Bucket lake is on stale volume ${PUBLISHED_ON}, unpublishing"
        # Despite `-h` calling the argument bucket_name, it takes a volume
        # handle: `unpublish lake` fails with "No such volume 'lake'".
        qm volume unpublish "My Tenant/${PUBLISHED_ON}"
    fi
    echo "[play] Publishing volume ${LAKE_VOLUME} as S3 bucket lake"
    qm volume publish "My Tenant/${LAKE_VOLUME}" lake
fi

echo "✓ Play clients deployed. Watch them with:"
echo "    task play:logs"
echo "    hubble observe -n quobyte-play -n quobyte --protocol http -f   (after task hubble)"
