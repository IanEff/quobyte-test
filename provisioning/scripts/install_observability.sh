#!/bin/bash
# quobyte-test — install_observability.sh
#
# Hubble metrics + L7 visibility, Prometheus scraping every Quobyte service
# and client, Grafana with Quobyte's and Cilium's dashboards. Runs from the
# laptop against an already-running cluster. Opens its own IAP tunnel if
# `task tunnel` isn't running (tunnel_lib.sh).
#
# Idempotent: helm upgrade --install and server-side apply throughout. The
# Cilium step only rolls the agents when the metrics config actually changes.
set -euo pipefail

KCTL_CONTEXT="${CLUSTER_NAME:-quobyte-test}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

kctl() { kubectl --context="${KCTL_CONTEXT}" "$@"; }
# shellcheck source=provisioning/scripts/tunnel_lib.sh
source "${REPO_ROOT}/provisioning/scripts/tunnel_lib.sh"
hlm() { helm --kube-context "${KCTL_CONTEXT}" "$@"; }

# Same pin as the VM bootstrap, read from there so the two can't drift.
# A --reuse-values upgrade without --version would jump to the latest chart.
CILIUM_VERSION=$(sed -n 's/^CILIUM_VERSION="\${CILIUM_VERSION:-\(.*\)}"$/\1/p' provisioning/scripts/install_cilium.sh)
PROMETHEUS_CHART_VERSION="29.33.0"
GRAFANA_CHART_VERSION="13.2.5"

if [ -z "${CILIUM_VERSION}" ]; then
    echo "[obs] ERROR: couldn't read CILIUM_VERSION from install_cilium.sh" >&2
    exit 1
fi

helm repo add cilium https://helm.cilium.io >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null
helm repo update cilium prometheus-community grafana-community >/dev/null

kctl create namespace monitoring --dry-run=client -o yaml | kctl apply -f -

echo "[obs] Cilium ${CILIUM_VERSION}: Hubble metrics + dashboards (cilium/values-observability.yaml)"
before=$(hlm get values cilium -n kube-system -o json)
hlm upgrade cilium cilium/cilium --version "${CILIUM_VERSION}" -n kube-system \
    --reuse-values -f cilium/values-observability.yaml --wait --timeout 10m >/dev/null
after=$(hlm get values cilium -n kube-system -o json)
# The chart doesn't roll agents on a ConfigMap change (rollOutCiliumPods is
# off), so new Hubble metrics would otherwise wait for the next reboot.
if [ "${before}" != "${after}" ]; then
    echo "[obs]   config changed, rolling cilium agents + operator"
    kctl -n kube-system rollout restart ds/cilium deploy/cilium-operator
    kctl -n kube-system rollout status ds/cilium --timeout 10m
    kctl -n kube-system rollout status deploy/cilium-operator --timeout 5m
fi

echo "[obs] Hubble L7/DNS visibility policies"
kctl apply -f quobyte/policies/

echo "[obs] Prometheus ${PROMETHEUS_CHART_VERSION}"
hlm upgrade --install prometheus prometheus-community/prometheus \
    --version "${PROMETHEUS_CHART_VERSION}" -n monitoring \
    -f quobyte/observability/values-prometheus.yaml --wait --timeout 10m

echo "[obs] Grafana ${GRAFANA_CHART_VERSION}"
hlm upgrade --install grafana grafana-community/grafana \
    --version "${GRAFANA_CHART_VERSION}" -n monitoring \
    -f quobyte/observability/values-grafana.yaml --wait --timeout 10m

# Server-side: the overview dashboard alone is over the 256 KiB limit for
# client-side apply's last-applied annotation.
echo "[obs] Quobyte dashboards + Grafana route"
kctl apply --server-side --force-conflicts -k quobyte/observability

echo "✓ Observability installed."
echo "    Grafana:    http://grafana.quobyte-test.lab   (anonymous view; admin/admin to edit)"
echo "    Hubble UI:  http://hubble.quobyte-test.lab"
echo "    Targets:    kubectl --context=${KCTL_CONTEXT} -n monitoring port-forward svc/prometheus-server 9090:80"
