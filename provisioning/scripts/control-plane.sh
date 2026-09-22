#!/bin/bash
# quobyte-test — control-plane.sh
# Installs k3s server, Helm, Cilium CNI, and the GCE PD CSI driver on the control plane node.
set -euo pipefail

if [ -f /etc/quobyte-test-control-plane.done ]; then
    echo "[control-plane.sh] Already provisioned, skipping."
    exit 0
fi

set -a
source /etc/quobyte-test.env
set +a

echo "══════════════════════════════════════════"
echo "  quobyte-test — control-plane setup     "
echo "══════════════════════════════════════════"

echo "[1] Common baseline (kernel modules, sysctl, packages)"
bash /quobyte-test/provisioning/scripts/common.sh

echo "[2] Install Helm"
HELM_VERSION="${HELM_VERSION:-v3.22.0}"
ARCH=$(dpkg --print-architecture)
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 5 \
     -o /tmp/helm.tar.gz \
     "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
tar -xzf /tmp/helm.tar.gz -C /tmp
install -m 755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
rm -rf /tmp/helm.tar.gz "/tmp/linux-${ARCH}"

echo "[3] Write k3s server config"
mkdir -p /etc/rancher/k3s
NODE_NAME=$(hostname -s)
cat > /etc/rancher/k3s/config.yaml <<EOF
advertise-address: ${CONTROL_PLANE_INTERNAL_IP}
node-ip: ${CONTROL_PLANE_INTERNAL_IP}
node-name: ${NODE_NAME}
token: ${K3S_TOKEN}
flannel-backend: "none"
disable-network-policy: true
disable-kube-proxy: true
disable:
  - traefik
  - servicelb
cluster-cidr: "10.244.0.0/16"
service-cidr: "10.96.0.0/12"
cluster-domain: "cluster.local"
secrets-encryption: true
node-taint:
  - "node-role.kubernetes.io/control-plane=true:NoSchedule"
tls-san:
  - "${CONTROL_PLANE_INTERNAL_IP}"
  - "${CONTROL_PLANE_EXTERNAL_IP}"
  - "127.0.0.1"
data-dir: "/var/lib/rancher/k3s"
EOF

echo "[4] Install k3s server (channel: ${K3S_CHANNEL})"
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 30 --retry 3 --retry-delay 5 \
     -o /tmp/k3s-install.sh https://get.k3s.io
chmod +x /tmp/k3s-install.sh
timeout 300 env INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" /tmp/k3s-install.sh
rm -f /tmp/k3s-install.sh

echo "[5] Wait for API server to respond"
until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes &>/dev/null; do
    sleep 3
done

echo "[6] Set up root kubeconfig"
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
sed -i "s/127\.0\.0\.1/${CONTROL_PLANE_INTERNAL_IP}/g" /root/.kube/config
export KUBECONFIG=/root/.kube/config

echo "[7] Install Cilium CNI & Gateway API"
bash /quobyte-test/provisioning/scripts/install_cilium.sh

echo "[8] Install GCE PD CSI driver"
bash /quobyte-test/provisioning/scripts/install_pd_csi.sh

touch /etc/quobyte-test-control-plane.done
echo "✓ control-plane.sh complete"
