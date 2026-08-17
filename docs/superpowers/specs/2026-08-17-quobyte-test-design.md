# quobyte-test Design Document

**Date:** 2026-08-17  
**Status:** Approved  
**Reference Rig:** `~/projects/ceph/thump-test`  
**Target Repo:** `~/projects/infra/quobyte-test`  
**Upstream Remote:** `https://github.com/IanEff/quobyte-test.git`

---

## 1. Objective & Scope

Stand up a throwaway GCP test cluster running Quobyte Free Edition on raw-VM k3s to evaluate:
1. GCE PD CSI out-of-tree dynamic volume provisioning on raw k3s.
2. Quobyte cluster installation (`quobyte-cluster` Helm chart) with 3/3/3 replicas on `pd-standard` devices.
3. Quobyte client & CSI driver dynamic RWX provisioning across worker nodes.
4. S3 Gateway access and path-style vs subdomain addressing via Cilium Gateway API.
5. Failure drill semantics (killing data pods, testing `podKiller` client restarts, volume detach, and `quobyte-reg-0` loss).
6. Capturing empirical findings for interview prep directly in `quobyte-test-running-notes.md`.

---

## 2. Ratified Architectural Decisions

| # | Decision | Rationale |
|---|---|---|
| **D-1** | **Raw-VM k3s on GCE**, not GKE | Preserves upstream Cilium, Hubble Relay & UI (GKE Dataplane V2 does not expose observer/peer services). |
| **D-2** | **GCE PD CSI driver** (`pd.csi.storage.gke.io`) | In-tree `kubernetes.io/gce-pd` was removed in k8s 1.31; required for modern cloud PD provisioning on raw VMs. |
| **D-3** | **Lean rig** (Tofu + k3s + Cilium/Hubble + Gateway API + `justfile`) | No Prometheus, Loki, Tempo, or ArgoCD. Maximizes CPU headroom under the 8 vCPU quota. |
| **D-4** | **Smallest disks possible**, all `pd-standard` | Avoids consuming any of the 250 GB regional `SSD_TOTAL_GB` quota (which covers `pd-balanced`). Registry/config PVCs use k3s `local-path`. |
| **D-5** | **Dynamic provisioning & failure eval**; license is observe-then-diff | First install unlicensed, observe behavior in webconsole, record in running notes, then import license key. |

---

## 3. Infrastructure & Sizing

### Compute Topology (8 E2 vCPUs Total)
- **Control Plane:** 1× `e2-medium` (2 vCPU, 4 GB RAM)
  - Tainted: `node-role.kubernetes.io/control-plane=true:NoSchedule`
  - Runs k3s server, Cilium Gateway Envoy (hostNetwork: 80/443/4245), Hubble Relay & UI.
- **Workers:** 3× `e2-standard-2` (2 vCPU, 8 GB RAM)
  - Runs Quobyte registry, data, metadata, client daemonset, CSI node daemonset.
  - Satisfies `podAntiAffinity` (`requiredDuringSchedulingIgnoredDuringExecution`) for 3 replicas across 3 nodes.

### Disk Footprint
- 4× 50 GB `pd-standard` boot disks = 200 GB.
- Data & Metadata devices: 6× CSI-provisioned `pd-standard` disks (Step-0 experiment will test 20Gi vs 100Gi minimum).
- Registry / config claims: 0 cloud disks (backed by k3s hostPath `local-path`).
- Total SSD quota: **0 GB**.

### Networking & Security
- Single VPC & custom subnet `10.10.0.0/24`.
- Port 22 (SSH) and 6443 (k3s API) restricted to Google IAP range `35.235.240.0/20`.
- Port 80, 443, 4245 restricted to user's detected external IP in `terraform.tfvars`.
- Cilium in `routingMode: tunnel` (Geneve) to guarantee cross-node pod-to-pod communication on GCP routed VPC.
- Gateway API Envoy in `hostNetwork: true` on control plane with `keepCapNetBindService: true` and `NET_ADMIN`/`SYS_ADMIN` capabilities.

---

## 4. Key Landmines & Mitigations

1. **k3s channel pinned to `v1.34`:** `quobyte-cluster` specifies `kubeVersion: "1.20-0 - 1.35-0"`. k3s `stable` is v1.36.3 and fails Helm validation.
2. **Quobyte sysctls in `common.sh`:** `net.core.rmem_max = 67108864`, `net.core.wmem_max = 1048576`.
3. **CSI & Client Namespace Defaults:** `values-client.yaml` and `values-csi.yaml` explicitly override registry DNS and API URLs to point to `quobyte.quobyte.svc.cluster.local`.
4. **License-free Client Flag:** `values-client.yaml` sets `enableAccessKeys: "false"`.
5. **StorageClass `faster`:** Rendered unconditionally by the cluster chart; configured with `storageProvisioner: pd.csi.storage.gke.io` and `flashStorage: pd-standard`.
6. **Device Mount Paths:** InitContainer globs `/var/lib/quobyte/devices/data*`, so disk names and mount paths match (`data0` -> `/var/lib/quobyte/devices/data0`).
7. **Rollout Timeouts:** `quobyte-cluster` uses `minReadySeconds: 180` for data/metadata StatefulSets. Helm timeout set to 20 minutes.

---

## 5. Verification Strategy

1. **Stage 1 (OpenTofu):** `tofu validate`, `tofu plan`, `tofu apply` creates 4 instances, 1 VPC, 1 subnet, 4 firewalls, 2 static IPs, 1 SA, 1 SA key.
2. **Stage 2 (k3s):** `just credentials` merges kubeconfig; `kubectl get nodes` reports 4 nodes `Ready` at `v1.34.10+k3s1`; sysctls verified on worker.
3. **Stage 3 (Cilium & Hubble):** Gateway API established; `cilium status --wait` passes; Hubble UI accessible via Gateway.
4. **Stage 4 (GCE PD CSI & Step-0):** Controller/node pods running; throwaway PVC binds; Step-0 probe tests 20Gi `qmkdev` registration.
5. **Stage 5 (Quobyte Cluster):** All Quobyte pods running; webconsole reachable at `http://quobyte.quobyte-test.lab` through Gateway; unlicensed behavior recorded.
6. **Stage 6 (Client & RWX):** `quobyte-client` and `quobyte-csi` healthy; two-pod anti-affined Deployment writes/reads shared RWX volume.
7. **Stage 7 (S3 Gateway):** S3 bucket created via `aws-cli` with `--force-path-style`; PUT and GET object verified.
8. **Stage 8 (Failure Drills):** Kill data pod, kill client pod to observe `podKiller`, detach device, kill `quobyte-reg-0` last.
