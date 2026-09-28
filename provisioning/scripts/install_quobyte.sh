#!/bin/bash
# quobyte-test — install_quobyte.sh
#
# Brings up the Quobyte layer on an already-running quobyte-test cluster:
# quobyte-cluster chart, qmgmt user bootstrap, Cilium Gateway routes, the
# client + CSI charts, and the RWX smoke test. Run locally (not on the
# control-plane node) against the kubeconfig `task credentials` already
# fetched — needs `helm` and `kubectl`. Manages its own IAP tunnel to
# 127.0.0.1:6443 for the duration of the install if one isn't already up
# (tunnel_lib.sh) — you don't need `task tunnel &` running first.
#
# Idempotent: `helm upgrade --install` + `kubectl apply` throughout, so a
# re-run against an already-provisioned cluster is safe.
set -euo pipefail

KCTL_CONTEXT="${CLUSTER_NAME:-quobyte-test}"
NAMESPACE="quobyte"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

kctl() { kubectl --context="${KCTL_CONTEXT}" "$@"; }

# shellcheck source=provisioning/scripts/tunnel_lib.sh
source "${REPO_ROOT}/provisioning/scripts/tunnel_lib.sh"

echo "══════════════════════════════════════════"
echo "  Installing Quobyte layer (context: ${KCTL_CONTEXT})"
echo "══════════════════════════════════════════"

# Chart sources. Quobyte now publishes charts as OCI artifacts under
# quay.io/quobyte/charts; the old GitHub Pages repo is frozen (cluster 0.3.0,
# client 0.3.4, csi 1.8.14). Client and CSI come from OCI at their latest.
# quobyte-cluster deliberately stays on 0.3.0 from the old repo: OCI 1.0.2
# drops PVC-backed data/metadata devices for node hostPath disks, which would
# mean redesigning this rig's PD-CSI device model. 0.3.0 caps k8s at 1.34
# (hence k3s_channel v1.34); the server image is overridden to 5.1 in
# values-cluster.yaml either way.
QUOBYTE_CLUSTER_CHART_VERSION="0.3.0"
QUOBYTE_CLIENT_CHART="oci://quay.io/quobyte/charts/quobyte-client"
QUOBYTE_CLIENT_CHART_VERSION="0.3.8"
QUOBYTE_CSI_CHART="oci://quay.io/quobyte/charts/quobyte-csi"
QUOBYTE_CSI_CHART_VERSION="2.4.0"

echo "[quobyte] Adding Quobyte Helm repository (quobyte-cluster only)"
helm repo add quobyte https://quobyte.github.io/quobyte-k8s-resources/helm-charts >/dev/null
helm repo update quobyte >/dev/null

kctl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kctl apply -f -

# The upstream quobyte-cluster chart stamps `timestamp: {{ now }}` into every
# workload's pod annotations (api/s3/webconsole Deployments, data/metadata/
# registry StatefulSets) with no values toggle to disable it — so a plain
# `helm upgrade --install` changes the pod-template hash and forces a full
# rolling restart on *every* run, even with byte-identical values. Combined
# with minReadySeconds=180s rolling one pod at a time on the StatefulSets,
# that turns every re-run of `task up` into an unwanted 10-20 min pod churn.
# Skip releases already `deployed` so re-runs are actually idempotent; set
# QUOBYTE_FORCE=1 to force a real upgrade (e.g. after changing chart version
# or values-*.yaml).
# Capture first, then match: piping straight into `grep -q` under pipefail
# lets grep's early exit SIGPIPE helm, which reads as "not deployed" and
# triggers the very upgrade this check exists to skip.
release_deployed() {
    local status
    status=$(helm status "$1" --kube-context "${KCTL_CONTEXT}" -n "${NAMESPACE}" 2>/dev/null) || return 1
    grep -q "^STATUS: deployed" <<<"${status}"
}

if [ "${QUOBYTE_FORCE:-}" != "1" ] && release_deployed quobyte-cluster; then
    echo "[quobyte] quobyte-cluster already deployed — skipping (set QUOBYTE_FORCE=1 to force a re-upgrade)"
else
    echo "[quobyte] Installing quobyte-cluster (budget ~10-20 min — minReadySeconds"
    echo "          is 180s on data/metadata StatefulSets, they roll one pod at a time)"
    helm upgrade --install quobyte-cluster quobyte/quobyte-cluster \
        --version "${QUOBYTE_CLUSTER_CHART_VERSION}" \
        --kube-context "${KCTL_CONTEXT}" \
        -n "${NAMESPACE}" -f "${REPO_ROOT}/quobyte/values-cluster.yaml" \
        --wait --timeout 20m
fi

# --- qmgmt bootstrap -------------------------------------------------------
# The internal user table starts empty, which blocks quobyte-csi dynamic
# provisioning with "unable to resolve user/group" until this runs.
#
# qm() and the exec-target selection live in qmgmt_lib.sh, shared with
# install_play.sh.
echo "[quobyte] Bootstrapping qmgmt user table (root/quobyte)"
# shellcheck source=provisioning/scripts/qmgmt_lib.sh
source "${REPO_ROOT}/provisioning/scripts/qmgmt_lib.sh"

# The user record stores tenants by UUID (member_of_tenant_id), so resolve
# the default tenant's UUID rather than trusting the name to be accepted.
# Retried: right after a fresh install the API can still be settling, and the
# first call has been seen to hit the 60s timeout (exit 124).
TENANT_UUID=""
for attempt in 1 2 3 4 5; do
    TENANT_UUID=$(qm tenant list 2>/dev/null | awk '/^My Tenant /{print $3}') || true
    [ -n "${TENANT_UUID}" ] && break
    echo "[quobyte]   qmgmt not answering yet (attempt ${attempt}/5), retrying in 15s"
    sleep 15
done
if [ -z "${TENANT_UUID}" ]; then
    echo "[quobyte] ERROR: could not resolve the UUID of tenant 'My Tenant' via qmgmt tenant list." >&2
    exit 1
fi

if ! qm user config add root root@quobyte-test.lab SUPER_USER quobyte \
    --member-of-tenant="${TENANT_UUID}" --primary-group=root; then
    echo "[quobyte] qmgmt user config add failed — may just mean root already exists; checking" >&2
fi

# The CSI provisioner needs root to exist *with* a primary group ("primary
# group is empty" otherwise), so verify rather than trust the add.
if ! qm user config list 2>/dev/null | grep -q "^root "; then
    echo "[quobyte] ERROR: root user missing after bootstrap — CSI provisioning will fail." >&2
    exit 1
fi
echo "[quobyte]   root user present (tenant ${TENANT_UUID}, primary group root)"

# The File Query Engine (and so every real MCP query) is license-gated; the
# unlicensed Free Edition answers "not enabled for the configured license".
# The key lives in a gitignored file because this repo is public. qmgmt has
# no `license show`, so import on every run; re-importing the same key is a
# no-op as far as we've seen.
LICENSE_FILE="${REPO_ROOT}/quobyte/license.key"
if [ -s "${LICENSE_FILE}" ]; then
    echo "[quobyte] Importing license from quobyte/license.key"
    qm license import "$(tr -d '[:space:]' <"${LICENSE_FILE}")"
else
    echo "[quobyte] No quobyte/license.key — staying on the unlicensed Free Edition (FQE/MCP queries will be denied)"
fi

echo "[quobyte] Applying Cilium Gateway routes"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/gateway-tls-secret.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/gateway.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/reference-grant.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/httproute-webconsole.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/httproute-hubble.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/httproute-s3.yaml"

echo "[quobyte] Applying S3 Service (targetPort 8484) + in-cluster DNS for s3.quobyte-test.lab"
kctl apply -f "${REPO_ROOT}/quobyte/s3/service.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/s3/coredns-custom.yaml"

# quay.io's CDN intermittently drops OCI blob downloads mid-stream ("Fetch
# ... EOF"), seen twice in a row on 2026-09-23 with a standalone pull
# succeeding a minute later. Retry rather than fail a 20-minute install.
retry() {
    local n
    for n in 1 2 3; do
        "$@" && return 0
        echo "[quobyte]   attempt ${n}/3 failed, retrying in 10s" >&2
        sleep 10
    done
    return 1
}

echo "[quobyte] Installing quobyte-client"
retry helm upgrade --install quobyte-client "${QUOBYTE_CLIENT_CHART}" \
    --version "${QUOBYTE_CLIENT_CHART_VERSION}" \
    --kube-context "${KCTL_CONTEXT}" \
    -n "${NAMESPACE}" -f "${REPO_ROOT}/quobyte/values-client.yaml" --wait

echo "[quobyte] Installing quobyte-csi"
retry helm upgrade --install quobyte-csi "${QUOBYTE_CSI_CHART}" \
    --version "${QUOBYTE_CSI_CHART_VERSION}" \
    --kube-context "${KCTL_CONTEXT}" \
    -n "${NAMESPACE}" -f "${REPO_ROOT}/quobyte/values-csi.yaml" --wait

echo "[quobyte] Applying RWX smoke test"
kctl apply -f "${REPO_ROOT}/quobyte/smoke/rwx-smoke.yaml"

echo "✓ Quobyte layer installed. Verify with:"
echo "    kubectl --context=${KCTL_CONTEXT} get pods -n ${NAMESPACE}"
echo "    kubectl --context=${KCTL_CONTEXT} get pods -n ${NAMESPACE} -l app=quobyte-smoke -o wide"
echo "    http://quobyte.quobyte-test.lab:8080  (after 'task hosts')"
