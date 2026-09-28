# quobyte-test — tunnel_lib.sh, sourced by the laptop-side install scripts.
# Expects KCTL_CONTEXT from the caller. Opens an IAP tunnel to the k3s API on
# 127.0.0.1:6443 for the caller's lifetime unless one is already up.
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
    PROJECT_ID="${PROJECT_ID:-$(tofu output -raw project_id 2>/dev/null || echo "terraform-sandbox-430820")}"
    ZONE="${ZONE:-$(tofu output -raw zone 2>/dev/null || echo "us-east1-b")}"
    echo "[tunnel] No IAP tunnel detected on 127.0.0.1:6443 — starting one for this script"
    gcloud compute start-iap-tunnel "${KCTL_CONTEXT}-control-plane" 6443 \
        --local-host-port=localhost:6443 --zone="${ZONE}" --project="${PROJECT_ID}" \
        >/tmp/quobyte-test-tunnel.log 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 30); do
        port_open && break
        sleep 1
    done
    if ! port_open; then
        echo "[tunnel] ERROR: IAP tunnel never came up — see /tmp/quobyte-test-tunnel.log" >&2
        exit 1
    fi
    echo "[tunnel]   tunnel ready (pid ${TUNNEL_PID}, will close when this script exits)"
else
    echo "[tunnel] Reusing existing tunnel/connection on 127.0.0.1:6443"
fi

