#!/bin/bash
# quobyte-test — install_quobyte.sh
#
# Brings up the Quobyte layer on an already-running quobyte-test cluster:
# quobyte-cluster chart, qmgmt user bootstrap, Cilium Gateway routes, the
# client + CSI charts, and the RWX smoke test. Run locally (not on the
# control-plane node) against the kubeconfig `task credentials` already
# fetched — needs `helm` and `kubectl`. Manages its own IAP tunnel to
# 127.0.0.1:6443 for the duration of the install if one isn't already up
# (see port_open/cleanup below) — you don't need `task tunnel &` running first.
#
# Idempotent: `helm upgrade --install` + `kubectl apply` throughout, so a
# re-run against an already-provisioned cluster is safe.
set -euo pipefail

KCTL_CONTEXT="${CLUSTER_NAME:-quobyte-test}"
NAMESPACE="quobyte"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

kctl() { kubectl --context="${KCTL_CONTEXT}" "$@"; }

port_open() {
    (exec 3<>/dev/tcp/127.0.0.1/6443) 2>/dev/null
}

# `task up` chains straight from `hosts` into this script with no tunnel
# running yet — `task tunnel` is deliberately foreground-blocking and meant
# for the user's own terminal (see the Taskfile), so nothing else starts it.
# If port 6443 isn't already open (either from a `task tunnel &` the user
# started themselves, or a prior run of this script), start one scoped to
# this script's own lifetime and tear it down on exit — never leaves a
# stray tunnel process behind, and never fights a tunnel the user is
# already running for their own kubectl access.
TUNNEL_PID=""
cleanup() {
    if [ -n "${TUNNEL_PID}" ]; then
        kill "${TUNNEL_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if ! port_open; then
    PROJECT_ID="${PROJECT_ID:-$(tofu output -raw project_id 2>/dev/null || gcloud config get-value project 2>/dev/null || echo "terraform-sandbox-430820")}"
    ZONE="${ZONE:-$(tofu output -raw zone 2>/dev/null || echo "us-east1-b")}"
    echo "[quobyte] No IAP tunnel detected on 127.0.0.1:6443 — starting one for this install"
    gcloud compute start-iap-tunnel "${KCTL_CONTEXT}-control-plane" 6443 \
        --local-host-port=localhost:6443 --zone="${ZONE}" --project="${PROJECT_ID}" \
        >/tmp/quobyte-install-tunnel.log 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 30); do
        port_open && break
        sleep 1
    done
    if ! port_open; then
        echo "[quobyte] ERROR: IAP tunnel never came up — see /tmp/quobyte-install-tunnel.log" >&2
        exit 1
    fi
    echo "[quobyte]   tunnel ready (pid ${TUNNEL_PID}, will close when this script exits)"
else
    echo "[quobyte] Reusing existing tunnel/connection on 127.0.0.1:6443"
fi

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
release_deployed() {
    helm status "$1" --kube-context "${KCTL_CONTEXT}" -n "${NAMESPACE}" 2>/dev/null \
        | grep -q "^STATUS: deployed"
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
# qmgmt is an API client and defaults to http://localhost:7860, which only
# answers inside an API pod — from any other pod it loops on "Connection
# refused" and then re-prompts "Username:" forever. So point it at the
# quobyte-api Service explicitly, and pipe credentials on stdin to answer
# the login prompt (an empty user table accepts them as default credentials).
# A hard `timeout` bounds any hang. The original bootstrap never created root
# because `timeout 60 kctl ...` exited 127 behind an `if !` that read it as
# "user already exists".
#
# Every Quobyte pod in this namespace shares the quay.io/quobyte/quobyte-server
# image and therefore ships the qmgmt binary, so pick any live one — prefer
# the webconsole pod (single, stable replica) and fall back to the first
# Running pod in the namespace.
echo "[quobyte] Bootstrapping qmgmt user table (root/quobyte)"
QMGMT_URL="http://quobyte-api:7860"
QMGMT_POD=$(kctl get pods -n "${NAMESPACE}" -l app=quobyte-web \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "${QMGMT_POD}" ]; then
    QMGMT_POD=$(kctl get pods -n "${NAMESPACE}" --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}')
fi
if [ -z "${QMGMT_POD}" ]; then
    echo "[quobyte] ERROR: no Running pod found in namespace ${NAMESPACE} to exec qmgmt against." >&2
    exit 1
fi
echo "[quobyte]   exec target: ${QMGMT_POD}"

qm() {
    # `timeout` runs inside the pod: kctl is a shell function, so a local
    # `timeout 60 kctl ...` can't exec it and exits 127 (command not found).
    printf 'root\nquobyte\n' | kctl exec -i "${QMGMT_POD}" -n "${NAMESPACE}" -- \
        timeout 60 qmgmt -u "${QMGMT_URL}" "$@"
}

# The user record stores tenants by UUID (member_of_tenant_id), so resolve
# the default tenant's UUID rather than trusting the name to be accepted.
TENANT_UUID=$(qm tenant list 2>/dev/null | awk '/^My Tenant /{print $3}')
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

echo "[quobyte] Applying Cilium Gateway routes"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/gateway-tls-secret.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/gateway.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/reference-grant.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/httproute-webconsole.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/httproute-hubble.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/httproute-s3.yaml"

echo "[quobyte] Installing quobyte-client"
helm upgrade --install quobyte-client "${QUOBYTE_CLIENT_CHART}" \
    --version "${QUOBYTE_CLIENT_CHART_VERSION}" \
    --kube-context "${KCTL_CONTEXT}" \
    -n "${NAMESPACE}" -f "${REPO_ROOT}/quobyte/values-client.yaml" --wait

echo "[quobyte] Installing quobyte-csi"
helm upgrade --install quobyte-csi "${QUOBYTE_CSI_CHART}" \
    --version "${QUOBYTE_CSI_CHART_VERSION}" \
    --kube-context "${KCTL_CONTEXT}" \
    -n "${NAMESPACE}" -f "${REPO_ROOT}/quobyte/values-csi.yaml" --wait

echo "[quobyte] Applying RWX smoke test"
kctl apply -f "${REPO_ROOT}/quobyte/smoke/rwx-smoke.yaml"

echo "✓ Quobyte layer installed. Verify with:"
echo "    kubectl --context=${KCTL_CONTEXT} get pods -n ${NAMESPACE}"
echo "    kubectl --context=${KCTL_CONTEXT} get pods -n ${NAMESPACE} -l app=quobyte-smoke -o wide"
echo "    http://quobyte.quobyte-test.lab:8080  (after 'task hosts')"
