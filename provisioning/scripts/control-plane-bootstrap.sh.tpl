#!/bin/bash
# quobyte-test — control-plane-bootstrap.sh.tpl
# Rendered by Tofu templatefile() into the control-plane instance metadata_startup_script.
# Writes interpolated values to /etc/quobyte-test.env, clones the repo, and execs control-plane.sh.
set -euo pipefail

cat > /etc/quobyte-test.env <<'ENVEOF'
CONTROL_PLANE_INTERNAL_IP=${control_plane_internal_ip}
CONTROL_PLANE_EXTERNAL_IP=${control_plane_external_ip}
K3S_TOKEN=${k3s_token}
K3S_CHANNEL=${k3s_channel}
GITOPS_REPO_URL=${gitops_repo_url}
PD_CSI_SA_KEY_B64=${pd_csi_sa_key_b64}
ENVEOF
chmod 600 /etc/quobyte-test.env

set -a
source /etc/quobyte-test.env
set +a

apt-get update -y
apt-get install -y git

git clone "$${GITOPS_REPO_URL}" /quobyte-test

exec bash /quobyte-test/provisioning/scripts/control-plane.sh
