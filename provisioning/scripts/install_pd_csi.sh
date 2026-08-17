#!/bin/bash
# quobyte-test — install_pd_csi.sh
# Deploys the out-of-tree GCE PD CSI driver on k3s using the scoped service account key.
set -euo pipefail

if [ -f /etc/quobyte-test.env ]; then
    set -a
    source /etc/quobyte-test.env
    set +a
fi

export KUBECONFIG=/root/.kube/config

echo "══════════════════════════════════════════"
echo "  Deploying GCE PD CSI Driver            "
echo "══════════════════════════════════════════"

export GOPATH=/tmp/go
export PKGDIR="${GOPATH}/src/sigs.k8s.io/gcp-compute-persistent-disk-csi-driver"
mkdir -p "$(dirname "${PKGDIR}")"
rm -rf "${PKGDIR}"
git clone https://github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver "${PKGDIR}"

mkdir -p /tmp/pd-csi-creds
echo "${PD_CSI_SA_KEY_B64}" | base64 -d > /tmp/pd-csi-creds/cloud-sa.json

cd "${PKGDIR}"
GOPATH=/tmp/go \
GCE_PD_SA_DIR=/tmp/pd-csi-creds \
GCE_PD_DRIVER_VERSION=stable-master \
  ./deploy/kubernetes/deploy-driver.sh --skip-sa-check

shred -u /tmp/pd-csi-creds/cloud-sa.json
rm -rf /tmp/pd-csi-creds /tmp/go

echo "✓ GCE PD CSI driver deployed successfully"
