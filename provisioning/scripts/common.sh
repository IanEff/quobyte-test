#!/bin/bash
# quobyte-test — common.sh
# Runs on every node (control plane + workers) during provisioning.
# Sets up kernel modules, sysctls (including Quobyte network buffers), and packages.
set -euo pipefail

if [ -f /etc/quobyte-test-common.done ]; then
    echo "[common.sh] Already provisioned, skipping."
    exit 0
fi

echo "══════════════════════════════════════════"
echo "  quobyte-test provisioning — common baseline"
echo "══════════════════════════════════════════"

echo "[1] Kernel modules for Kubernetes"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "[2] Sysctl: IP forwarding + bridge netfilter"
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

echo "[2b] Sysctl: Quobyte network buffers"
cat > /etc/sysctl.d/quobyte.conf <<EOF
net.core.rmem_max = 67108864
net.core.wmem_max = 1048576
EOF
sysctl --system >/dev/null

echo "[3] k3s containerd registry mirrors"
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
      - "https://quay.io"
  registry-1.docker.io:
    endpoint:
      - "https://registry-1.docker.io"
  registry.k8s.io:
    endpoint:
      - "https://registry.k8s.io"
  ghcr.io:
    endpoint:
      - "https://ghcr.io"
  quay.io:
    endpoint:
      - "https://quay.io"
      - "https://registry-1.docker.io"
EOF

echo "[4] Robust APT settings"
cat > /etc/apt/apt.conf.d/99robust <<EOF
Acquire::Retries "10";
Acquire::ForceIPv4 "true";
Acquire::https::Timeout "60";
Acquire::http::Timeout "60";
Acquire::http::Pipeline-Depth "0";
EOF
apt-get update

echo "[5] Install base packages"
apt-get install -y \
    apt-transport-https ca-certificates curl gpg \
    open-iscsi nfs-common udev \
    git vim bash-completion wget jq \
    ripgrep tmux fish
systemctl enable --now iscsid

echo "[6] Shell ergonomics — fish, bash, vim, tmux"
for TARGET_HOME in /etc/skel /root; do
    mkdir -p "${TARGET_HOME}/.config/fish/conf.d"
    cat > "${TARGET_HOME}/.config/fish/conf.d/quobyte-test.fish" <<'FISH'
# ── Quobyte / k8s shortcuts ──────────────────────────────────────────────────
abbr -a qpods          'kubectl get pods -n quobyte'
abbr -a qpvc           'kubectl get pvc -n quobyte'
abbr -a qsvc           'kubectl get svc -n quobyte'
abbr -a kpa            'kubectl get pods -A'
abbr -a watch-qpods    'watch kubectl get pods -n quobyte'
abbr -a hubble-q       'hubble observe --namespace quobyte'
abbr -a hubble-drops   'hubble observe --verdict DROPPED'
FISH

    cat >> "${TARGET_HOME}/.bashrc" 2>/dev/null <<'BASH' || true
alias qpods='kubectl get pods -n quobyte'
alias qpvc='kubectl get pvc -n quobyte'
alias qsvc='kubectl get svc -n quobyte'
alias kpa='kubectl get pods -A'
alias watch-qpods='watch kubectl get pods -n quobyte'
alias hubble-q='hubble observe --namespace quobyte'
alias hubble-drops='hubble observe --verdict DROPPED'

__ps1_k8s() { kubectl config current-context 2>/dev/null || echo '—'; }
export PROMPT_COMMAND='PS1="\[\e[1;36m\]k8s:\[\e[0m\]$(__ps1_k8s) \w \$ "'
BASH

    cat > "${TARGET_HOME}/.vimrc" <<'VIM'
syntax on
set number relativenumber
set tabstop=2 shiftwidth=2 expandtab
set incsearch hlsearch
set encoding=utf-8
colorscheme desert
VIM

    cat > "${TARGET_HOME}/.tmux.conf" <<'TMUX'
set -g mouse on
set -g default-terminal "screen-256color"
set -g status-style "bg=colour235,fg=colour136"
set -g status-left  "#[fg=colour166,bold]  quobyte-test  #[default]"
set -g status-right "#[fg=colour33]%H:%M  %d-%b  #[fg=colour166]#H"
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
TMUX
done

touch /etc/quobyte-test-common.done
echo "✓ common.sh complete"
