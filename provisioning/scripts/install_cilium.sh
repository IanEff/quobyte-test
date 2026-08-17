#!/bin/bash
# quobyte-test — install_cilium.sh
# Installs Gateway API CRDs, Cilium CNI (tunnel mode), and Hubble CLI.
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.19.3}"
HUBBLE_VERSION="${HUBBLE_VERSION:-v1.19.3}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.1}"
CONTROL_PLANE_INTERNAL_IP="${CONTROL_PLANE_INTERNAL_IP:?CONTROL_PLANE_INTERNAL_IP not set}"

export KUBECONFIG=/root/.kube/config

echo "[cilium] Gateway API CRDs (${GATEWAY_API_VERSION})"
kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

echo "[cilium] Waiting for Gateway API CRDs to be established..."
kubectl wait --for=condition=Established \
    crd/gateways.gateway.networking.k8s.io \
    crd/httproutes.gateway.networking.k8s.io \
    crd/gatewayclasses.gateway.networking.k8s.io \
    crd/grpcroutes.gateway.networking.k8s.io \
    --timeout=60s

echo "[cilium] Adding Cilium Helm repository"
helm repo add cilium https://helm.cilium.io/
helm repo update cilium

echo "[cilium] Installing Cilium ${CILIUM_VERSION}"
helm upgrade --install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set k8sServiceHost="${CONTROL_PLANE_INTERNAL_IP}" \
    --set k8sServicePort="6443" \
    --set routingMode=tunnel \
    --set tunnelProtocol=vxlan \
    --set gatewayAPI.enabled=true \
    --set gatewayAPI.hostNetwork.enabled=true \
    --set gatewayAPI.hostNetwork.nodeLabelSelector."node-role\.kubernetes\.io/control-plane"="true" \
    --set envoy.securityContext.capabilities.keepCapNetBindService=true \
    --set envoy.securityContext.capabilities.envoy="{NET_ADMIN,SYS_ADMIN,NET_BIND_SERVICE}" \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set operator.replicas=1 \
    --set prometheus.serviceMonitor.trustCRDsExist=false \
    --wait --timeout 10m

echo "[cilium] Installing Hubble CLI"
ARCH=$(dpkg --print-architecture)
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 5 \
     -o /tmp/hubble.tar.gz \
     "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-${ARCH}.tar.gz"
tar -xzf /tmp/hubble.tar.gz -C /tmp hubble
install -m 755 /tmp/hubble /usr/local/bin/hubble
rm -f /tmp/hubble.tar.gz /tmp/hubble

echo "✓ Cilium ${CILIUM_VERSION} installed with Hubble + Gateway API"
