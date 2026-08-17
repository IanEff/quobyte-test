#!/usr/bin/env python3
"""Fetch and merge kubeconfig for the quobyte-test cluster.

Connects via `gcloud compute ssh ... --tunnel-through-iap`, fetches /root/.kube/config,
rewrites the server IP to 127.0.0.1 (for local IAP port forwarding), and merges it into ~/.kube/config.

Usage:
    python3 fetch_kubeconfig.py add
    python3 fetch_kubeconfig.py remove
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

KUBE_CONFIG_PATH = Path.home() / ".kube" / "config"

NEW_CONTEXT_NAME = "quobyte-test"
NEW_USER_NAME = "quobyte-test-admin"
NEW_CLUSTER_NAME = "quobyte-test-cluster"

KUBECONFIG_WAIT_TIMEOUT_S = 600
KUBECONFIG_WAIT_INTERVAL_S = 10


def tofu_output(name: str) -> str:
    result = subprocess.run(
        ["tofu", "output", "-raw", name],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"tofu output -raw {name} failed: {result.stderr.strip()}", file=sys.stderr)
        print("Run this from the repo root after `tofu apply`.", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def backup_file(path: Path) -> None:
    if path.exists():
        backup_path = path.with_suffix(f".bak.{int(time.time())}")
        shutil.copy2(path, backup_path)
        print(f"Backed up {path.name} to {backup_path.name}")


def add() -> None:
    project_id = os.environ.get("PROJECT_ID") or tofu_output("project_id")
    zone = os.environ.get("ZONE") or tofu_output("zone")
    cluster_name = os.environ.get("CLUSTER_NAME") or tofu_output("cluster_name")
    internal_ip = tofu_output("control_plane_internal_ip")

    instance = f"{cluster_name}-control-plane"
    cmd = [
        "gcloud", "compute", "ssh", instance,
        f"--zone={zone}", f"--project={project_id}", "--tunnel-through-iap",
        "--command=sudo cat /root/.kube/config",
    ]

    print(f"Fetching kubeconfig from {instance} via gcloud compute ssh (IAP)...")
    print(f"  (retrying up to {KUBECONFIG_WAIT_TIMEOUT_S}s — waiting for k3s & Cilium install to complete)")
    deadline = time.time() + KUBECONFIG_WAIT_TIMEOUT_S
    attempt = 0
    while True:
        attempt += 1
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip() and "BEGIN CERTIFICATE" in result.stdout:
            break
        if time.time() >= deadline:
            print(f"Failed to fetch kubeconfig after {KUBECONFIG_WAIT_TIMEOUT_S}s "
                  f"({attempt} attempts): {result.stderr.strip()}", file=sys.stderr)
            sys.exit(1)
        print(f"  attempt {attempt}: not ready yet, retrying in {KUBECONFIG_WAIT_INTERVAL_S}s...")
        time.sleep(KUBECONFIG_WAIT_INTERVAL_S)

    tmpdir = Path(tempfile.mkdtemp(prefix="quobyte_k3s_"))
    temp_conf = tmpdir / "k3s.yaml"
    merged_conf = tmpdir / "kubeconfig.merged"
    try:
        content = result.stdout
        # Rewrite server URL: internal IP -> 127.0.0.1 (matches local `just tunnel` forwarding)
        content = content.replace(internal_ip, "127.0.0.1")
        content = content.replace("current-context: default", f"current-context: {NEW_CONTEXT_NAME}")
        content = re.sub(r"\bcluster: default\b", f"cluster: {NEW_CLUSTER_NAME}", content)
        content = re.sub(r"\buser: default\b", f"user: {NEW_USER_NAME}", content)
        content = re.sub(r"(- context:(?:.|\n)*?name:)\s+default", rf"\1 {NEW_CONTEXT_NAME}", content)
        content = re.sub(r"(- cluster:(?:.|\n)*?name:)\s+default", rf"\1 {NEW_CLUSTER_NAME}", content)
        content = re.sub(r"(?m)^- name:\s+default$", f"- name: {NEW_USER_NAME}", content)
        temp_conf.write_text(content, encoding="utf-8")

        print("Merging kubeconfig...")
        env = os.environ.copy()
        env["KUBECONFIG"] = f"{temp_conf}:{KUBE_CONFIG_PATH}" if KUBE_CONFIG_PATH.exists() else str(temp_conf)
        with open(merged_conf, "w") as f:
            merge = subprocess.run(["kubectl", "config", "view", "--flatten"], env=env, stdout=f)
        if merge.returncode != 0:
            print("Failed to merge kubeconfig.", file=sys.stderr)
            sys.exit(1)

        backup_file(KUBE_CONFIG_PATH)
        KUBE_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(merged_conf), KUBE_CONFIG_PATH)
        KUBE_CONFIG_PATH.chmod(0o600)
        print(f"✓ Kubeconfig updated. Context '{NEW_CONTEXT_NAME}' is now current.")
        print("  Server: https://127.0.0.1:6443 (run `just tunnel &` to start the IAP tunnel)")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def remove() -> None:
    print("Removing quobyte-test Kubernetes configuration...")
    cmds = [
        ["kubectl", "config", "delete-context", NEW_CONTEXT_NAME],
        ["kubectl", "config", "delete-cluster", NEW_CLUSTER_NAME],
        ["kubectl", "config", "delete-user", NEW_USER_NAME],
    ]
    for cmd in cmds:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("✓ Kubeconfig cleaned up.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["add", "remove"])
    args = parser.parse_args()
    add() if args.action == "add" else remove()


if __name__ == "__main__":
    main()
