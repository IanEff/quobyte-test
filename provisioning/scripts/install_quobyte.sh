#!/bin/bash
# quobyte-test — install_quobyte.sh
#
# Brings up the Quobyte layer on an already-running quobyte-test cluster:
# quobyte-cluster chart, qmgmt user bootstrap, Cilium Gateway routes, the
# client + CSI charts, and the RWX smoke test. Run locally (not on the
# control-plane node) against the kubeconfig `task credentials` already
# fetched — needs `helm`, `kubectl`, and a live IAP tunnel (`task tunnel &`).
#
# Idempotent: `helm upgrade --install` + `kubectl apply` throughout, so a
# re-run against an already-provisioned cluster is safe.
set -euo pipefail

KCTL_CONTEXT="${CLUSTER_NAME:-quobyte-test}"
NAMESPACE="quobyte"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

kctl() { kubectl --context="${KCTL_CONTEXT}" "$@"; }

echo "══════════════════════════════════════════"
echo "  Installing Quobyte layer (context: ${KCTL_CONTEXT})"
echo "══════════════════════════════════════════"

echo "[quobyte] Adding Quobyte Helm repository"
helm repo add quobyte https://quobyte.github.io/quobyte-k8s-resources/helm-charts >/dev/null
helm repo update quobyte >/dev/null

kctl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kctl apply -f -

echo "[quobyte] Installing quobyte-cluster (budget ~10-20 min — minReadySeconds"
echo "          is 180s on data/metadata StatefulSets, they roll one pod at a time)"
helm upgrade --install quobyte-cluster quobyte/quobyte-cluster \
    --kube-context "${KCTL_CONTEXT}" \
    -n "${NAMESPACE}" -f "${REPO_ROOT}/quobyte/values-cluster.yaml" \
    --wait --timeout 20m

# --- qmgmt bootstrap -------------------------------------------------------
# The internal user table starts empty, which blocks quobyte-csi dynamic
# provisioning with "unable to resolve user/group" until this runs.
#
# Known upstream landmine: qmgmt write commands (this one included) don't
# fail cleanly without a real TTY — a rejected/empty answer just re-prompts
# forever instead of erroring out. Defend against that here: no stdin to
# read from (</dev/null, so a stray prompt can't block on it) and a hard
# `timeout` so a hang fails loud in under a minute instead of wedging the
# whole install. Read-only qmgmt commands (tenant list, etc.) don't have
# this problem — only write commands do.
#
# Exec target: never recorded anywhere (checked the repo, running notes, and
# the assembly sheet — only the qmgmt command text survived, not which pod it
# ran against). Every Quobyte pod in this namespace shares the same
# quay.io/quobyte/quobyte-server image and therefore ships the qmgmt binary,
# so pick any live one — prefer the webconsole pod (single, stable replica)
# and fall back to the first Running pod in the namespace.
echo "[quobyte] Bootstrapping qmgmt user table (root/quobyte)"
QMGMT_POD=$(kctl get pods -n "${NAMESPACE}" -l app=quobyte-webconsole \
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

if ! timeout 60 kctl exec -i "${QMGMT_POD}" -n "${NAMESPACE}" -- \
    qmgmt user config add root root@quobyte-test.lab SUPER_USER quobyte \
    --member-of-tenant="My Tenant" --primary-group=root </dev/null; then
    echo "[quobyte] WARNING: qmgmt bootstrap timed out or failed — this may just mean the" >&2
    echo "[quobyte]   user already exists (safe to ignore on a re-run) or it hit the known" >&2
    echo "[quobyte]   non-interactive-hang issue (see README 'Known issues'). Verify manually:" >&2
    echo "[quobyte]     kubectl --context=${KCTL_CONTEXT} exec -it ${QMGMT_POD} -n ${NAMESPACE} -- qmgmt user config list" >&2
fi

echo "[quobyte] Applying Cilium Gateway routes"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/gateway-tls-secret.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/gateway.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/reference-grant.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/httproute-webconsole.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/httproute-hubble.yaml"
kctl apply -f "${REPO_ROOT}/quobyte/gateway/httproute-s3.yaml"

echo "[quobyte] Installing quobyte-client"
helm upgrade --install quobyte-client quobyte/quobyte-client \
    --kube-context "${KCTL_CONTEXT}" \
    -n "${NAMESPACE}" -f "${REPO_ROOT}/quobyte/values-client.yaml" --wait

echo "[quobyte] Installing quobyte-csi"
helm upgrade --install quobyte-csi quobyte/quobyte-csi \
    --kube-context "${KCTL_CONTEXT}" \
    -n "${NAMESPACE}" -f "${REPO_ROOT}/quobyte/values-csi.yaml" --wait

echo "[quobyte] Applying RWX smoke test"
kctl apply -f "${REPO_ROOT}/quobyte/smoke/rwx-smoke.yaml"

echo "✓ Quobyte layer installed. Verify with:"
echo "    kubectl --context=${KCTL_CONTEXT} get pods -n ${NAMESPACE}"
echo "    kubectl --context=${KCTL_CONTEXT} get pods -n ${NAMESPACE} -l app=quobyte-smoke -o wide"
echo "    http://quobyte.quobyte-test.lab:8080  (after 'task hosts')"
