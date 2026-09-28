# quobyte-test — qmgmt_lib.sh, sourced by install_quobyte.sh and install_play.sh.
# Expects kctl() and NAMESPACE from the caller. Defines qm(), which runs
# qmgmt as root/quobyte inside a Quobyte pod.
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
QMGMT_URL="http://quobyte-api:7860"
QMGMT_POD=$(kctl get pods -n "${NAMESPACE}" -l app=quobyte-web \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "${QMGMT_POD}" ]; then
    QMGMT_POD=$(kctl get pods -n "${NAMESPACE}" --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}')
fi
if [ -z "${QMGMT_POD}" ]; then
    echo "[qmgmt] ERROR: no Running pod found in namespace ${NAMESPACE} to exec qmgmt against." >&2
    exit 1
fi
echo "[qmgmt]   exec target: ${QMGMT_POD}"

qm() {
    # `timeout` runs inside the pod: kctl is a shell function, so a local
    # `timeout 60 kctl ...` can't exec it and exits 127 (command not found).
    printf 'root\nquobyte\n' | kctl exec -i "${QMGMT_POD}" -n "${NAMESPACE}" -- \
        timeout 60 qmgmt -u "${QMGMT_URL}" "$@"
}
