#!/bin/bash
# quobyte-test — install_pd_csi.sh
# Deploys the out-of-tree GCE PD CSI driver on k3s using the scoped service account key.
set -euo pipefail

export KUBECONFIG=/root/.kube/config

echo "══════════════════════════════════════════"
echo "  Deploying GCE PD CSI Driver            "
echo "══════════════════════════════════════════"

rm -rf /tmp/pd-csi /tmp/pd-csi-creds
git clone https://github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver /tmp/pd-csi
cd /tmp/pd-csi

mkdir -p /tmp/pd-csi-creds
echo "${PD_CSI_SA_KEY_B64}" | base64 -d > /tmp/pd-csi-creds/cloud-sa.json

GCE_PD_SA_DIR=/tmp/pd-csi-creds \
GCE_PD_DRIVER_VERSION=stable-master \
  ./deploy/kubernetes/deploy-driver.sh

shred -u /tmp/pd-csi-creds/cloud-sa.json
rm -rf /tmp/pd-csi-creds /tmp/pd-csi

echo "✓ GCE PD CSI driver deployed successfully"
