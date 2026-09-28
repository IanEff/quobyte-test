# quobyte-test

A throwaway GCP sandbox: Quobyte 5.1 Free Edition on k3s on raw VMs, built by
`task up` and destroyed by `task destroy`. It exercises out-of-tree GCE PD CSI
dynamic provisioning, cross-node RWX file storage, Cilium in VXLAN tunnel mode
with Hubble, and Quobyte's S3 gateway and MCP endpoint.

> **Ephemeral and unmaintained.** Every resource it creates is meant to be torn
> down after use. Versions are pinned to what worked when it was written, and
> they will drift out of date. Nothing here is a reference architecture.
>
> **Machine-generated.** Nearly all of the code, manifests and prose in this
> repo, this README included, were written by Claude Code (Anthropic's coding
> agent) under the stern, watchful gaze of Captain
> Ian E. Furst, engineer currently very much at large. It worked on the rig it
> was built for, and that is the full extent of its testing. The agent did the
> work, and the Captain is grateful.

## Architecture

| Layer          | What runs                                                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Infrastructure | OpenTofu on Google Cloud                                                                                                        |
| Topology       | 1× `e2-medium` control plane + 3× `e2-highmem-2` workers (2 vCPU / 16 GB each; 8 E2 vCPUs total) in `us-east1-b`                |
| Disks          | `pd-standard` only, boot and CSI (0 GB SSD quota used)                                                                          |
| Kubernetes     | k3s channel `v1.34`, latest patch. `quobyte-cluster` 0.3.0 caps k8s below 1.35, so this is the ceiling                          |
| Networking     | Cilium 1.20.2 in VXLAN tunnel mode, hostNetwork Gateway API (CRDs v1.6.1), Hubble Relay and UI                                  |
| Observability  | Hubble metrics, L7/DNS visibility CNPs, Prometheus scraping every Quobyte service and client, Grafana with Quobyte's dashboards |
| Storage        | Out-of-tree GCE PD CSI driver + Quobyte 5.1, server and client images pinned by digest                                          |

Charts: `quobyte-cluster` 0.3.0 from the legacy helm repo; `quobyte-client`
0.3.8 and `quobyte-csi` 2.4.0 from OCI (`quay.io/quobyte/charts`).
`quobyte-cluster` stays on 0.3.0 because the newer OCI 1.0.2 chart moves data
and metadata devices from PVCs to hostPath disks on the node, which would mean
redesigning this rig's PD-CSI device model. 0.3.0 runs the 5.1 image fine.

## Quickstart

Shell snippets in this README are [fish](https://fishshell.com/).

```fish
# 1. Initialize and review the plan
task init
task plan

# 2. Create the VMs, fetch credentials, and install the Quobyte layer
#    (helm charts, qmgmt bootstrap, gateway and smoke manifests)
task up

# 3. Open a background IAP tunnel for kubectl
task tunnel &

# 4. Verify nodes
kubectl --context=quobyte-test get nodes -o wide

# 5. Tear down. Quobyte's helm releases are uninstalled first, so
#    CSI-provisioned PDs are reclaimed before the VMs are destroyed.
task destroy
```

`task --list` shows every task, including `task quobyte:up` and
`task quobyte:down` for installing or removing only the Quobyte layer on a
running cluster.

## Endpoints

`task up` runs `task hosts`, which writes these hostnames into `/etc/hosts`
pointing at the control plane's external IP:

| Service            | URL                                                                      | Login                                     |
| ------------------ | ------------------------------------------------------------------------ | ----------------------------------------- |
| Quobyte webconsole | `http://quobyte.quobyte-test.lab:8080`                                   | `root` / `quobyte`                        |
| Hubble UI          | `http://hubble.quobyte-test.lab`                                         | none                                      |
| S3 gateway         | `http://s3.quobyte-test.lab` (path-style; see [S3 gateway](#s3-gateway)) | access key from `task play:up`            |
| Grafana            | `http://grafana.quobyte-test.lab`                                        | anonymous view; `admin` / `admin` to edit |

They're reachable directly over the internet, without `task tunnel`. The
Gateway listens on the control plane's `hostNetwork`, and the `allow-gateway`
firewall rule in `network.tf` opens ports 80, 443, 4245 and 8080 to the
addresses in `allowed_source_ranges` (`terraform.tfvars`). Only `kubectl` and
`helm` against port 6443 need the tunnel; that port stays IAP-only.

When your IP changes (VPNs do this), update `allowed_source_ranges` and apply
**only the firewall**:

```fish
env -u TF_DATA_DIR tofu apply -target=google_compute_firewall.allow_gateway
```

⚠️ Don't run a plain `task apply` for this. On a running cluster the plan
detaches the CSI-attached `pvc-*` disks from the nodes (`attached_disk` drift
on `google_compute_instance.node`), and those disks are Quobyte's devices.

## Using it

### Credentials

The webconsole, `qmgmt`, and the CSI driver's provisioner secret all use the
single bootstrap superuser that `install_quobyte.sh` creates:

```
username: root
password: quobyte
tenant:   My Tenant
```

The password is hardcoded in `install_quobyte.sh`. The firewall allowlist is
what keeps it off the open internet.

### Cluster and Quobyte health

```fish
kubectl --context=quobyte-test get nodes -o wide
kubectl --context=quobyte-test get pods -n quobyte -o wide
kubectl --context=quobyte-test get pods -n quobyte -l app=quobyte-smoke -o wide   # RWX smoke deployment
```

### RWX (ReadWriteMany)

`task up` applies `quobyte/smoke/rwx-smoke.yaml`: a 2-replica Deployment,
spread across nodes by `podAntiAffinity`, sharing one PVC. Each replica writes
its own timestamped file and lists everything it can see.

```fish
kubectl --context=quobyte-test logs -n quobyte -l app=quobyte-smoke --tail=5 --prefix
```

Each pod's log should list _both_ pods' `.txt` files under `/mnt/quobyte/`.
If it does, cross-node RWX works. The `quobyte-smoke` PVC also shows up as a
registered volume in the webconsole.

### `qmgmt`

`qmgmt` ships in every Quobyte pod, since they all share the server image. It's
an API client that defaults to `localhost:7860`, so outside an API pod it needs
`-u` pointed at the `quobyte-api` Service. It prompts for a login; pipe the
credentials in (see [Known issues](#known-issues) for why).

```fish
set -g QMGMT_POD (kubectl --context=quobyte-test get pods -n quobyte -l app=quobyte-web -o name | head -1)
function qm
    printf 'root\nquobyte\n' | kubectl --context=quobyte-test exec -i $QMGMT_POD -n quobyte -- qmgmt -u http://quobyte-api:7860 $argv
end

qm tenant list
qm user config list
qm volume list
```

### S3 gateway

Quobyte 5.1's S3 gateway defaults to a 10 GiB object cache and crash-loops on
8 GB nodes with "Configured object cache size is too large". The workers are
`e2-highmem-2` (16 GB) instead of `e2-standard-2` for that reason alone.

`install_quobyte.sh` applies two fixes to make the gateway reachable:

1. **The chart's Service targets the wrong port.** `quobyte-cluster` 0.3.0
   sets `QUOBYTE_S3_PORT=8484` on the pod but hardcodes `targetPort: 80` on
   the `quobyte-s3` Service. 5.1 listens on 8484, so that Service reaches
   nothing. `quobyte/s3/service.yaml` adds `quobyte-s3-gw` (80 → 8484), and
   the HTTPRoute uses it.
2. **The gateway routes on the Host header.** Any Host other than
   `s3.quobyte-test.lab` is read as a virtual-host bucket name, so
   `http://quobyte-s3-gw.quobyte.svc` returns `NoSuchBucket`. In-cluster
   clients use the real hostname, and `quobyte/s3/coredns-custom.yaml`
   rewrites it to the Service in k3s's CoreDNS.

`task play:up` mints an access key into the `quobyte-play/s3-credentials`
Secret. To use S3 from your laptop, read the key back and force path-style
addressing, since virtual-hosted `<bucket>.s3.quobyte-test.lab` won't resolve:

```fish
set -gx AWS_ACCESS_KEY_ID (kubectl --context=quobyte-test -n quobyte-play get secret s3-credentials -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
set -gx AWS_SECRET_ACCESS_KEY (kubectl --context=quobyte-test -n quobyte-play get secret s3-credentials -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
aws configure set default.s3.addressing_style path

aws --endpoint-url http://s3.quobyte-test.lab s3 ls
aws --endpoint-url http://s3.quobyte-test.lab s3 ls s3://lake/ --recursive | head
```

Buckets created over S3 (warp's `warp-bench`, for one) appear in every
client's mount under `/home/quobyte/mounts/S3 Buckets/`. It works in reverse
too: `qmgmt volume publish <tenant>/<volume> <bucket>` exposes an existing
POSIX volume as a bucket, which is how the `lake` bucket is made.

### Hubble

`task observability:up` (part of `task up`) applies
`quobyte/policies/cnp-quobyte-visibility.yaml`. The policy sets
`enableDefaultDeny: false` in both directions, so it only adds visibility and
never drops traffic. It sends Quobyte's three HTTP front doors through Cilium's
L7 proxy (API/MCP on 7860, S3 on 8484, webconsole on 8080) and every DNS lookup
through the DNS proxy. Quobyte's own RPC (registry 7861, metadata 7862, data
7863, TCP and UDP) isn't HTTP, so it stays at L4, which Hubble shows without
any policy.

```fish
task tunnel &
task hubble &     # relay -> localhost:4245

# S3 at L7: method, path, status, latency. Multipart uploads show up as
# parallel PUT ...?partNumber=N&uploadId=... then the completing POST.
hubble observe -n quobyte --protocol http -f

# The data path under a CSI mount: client DaemonSet -> metadata (7862),
# then fan-out to all three data services (7863).
hubble observe --from-label role=client -f

# What names the play clients resolve.
hubble observe --from-namespace quobyte-play --protocol dns
```

The Hubble UI at `http://hubble.quobyte-test.lab` shows the same flows as a
service map; pick the `quobyte` namespace.

### Grafana

Prometheus scrapes every Quobyte service at `/prometheus` on its HTTP status
port (RPC port + 10, so 7871–7876) and each client on 55000, with no auth.
Quobyte's example config discovers targets through the registry's
Consul-style catalog on 7871, but on this cluster that endpoint hangs.
`quobyte/observability/values-prometheus.yaml` uses Kubernetes pod discovery
instead and rebuilds the labels Quobyte's dashboards expect
(`quobyte_cluster`, `service_type`, `instance`).

The **Quobyte** folder holds three dashboards vendored from
[quobyte/quobyte-dashboards](https://github.com/quobyte/quobyte-dashboards)
(_Quobyte Dashboard 3.x_, _Performance Dashboard Data_, _Storage
availability_) and one local to this repo, _Quobyte Filer_: client IOPS,
throughput and latency, metadata ops, device latency, and S3 at L7. Cilium's
and Hubble's dashboards sit alongside them, including per-workload HTTP RED
(the `httpV2` metric) for anything the visibility policy proxies.

### Play clients

`task play:up` (part of `task up`) deploys `quobyte/play/` into the
`quobyte-play` namespace. Each client tests one specific behavior:

| Client         | What it does                                                                                                                                                               | What to look for                                                                                                                                 |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `trainer`      | Every 60s, writes a 4×32 MiB "checkpoint" with fsync and a sha256 manifest, then renames `LATEST` over the old one. Keeps 3.                                               | Write MiB/s per step                                                                                                                             |
| `evaluator` ×2 | On other nodes, follows `LATEST` and re-hashes every shard                                                                                                                 | `OK` / `MISMATCH` / `ORDERING`. `ORDERING` means a node saw the rename before the data it points to, which would break close-to-open consistency |
| `crossproto`   | Writes a file through the mount and polls for it over S3; PUTs over S3 and polls the mount. Every 6th round, a 48 MiB multipart upload checked by sha256 through the mount | Cross-protocol visibility latency (~40 ms and ~15 ms on this rig)                                                                                |
| `metastorm`    | 1000 tiny files per round: create, stat, readdir, rename, chmod+append, unlink                                                                                             | ops/s per phase. Create and rename run at ~20/s here, stat at ~550/s                                                                             |
| `datagen`      | One-shot: a fake research group's home volume (~1500 files, 3 years of mtimes, sparse multi-GiB checkpoints, stale scratch, world-writable drops, a departed user)         | Material for the File Query Engine and MCP to answer questions about                                                                             |

```fish
task play:logs     # tail them all
task play:bench    # 3-minute MinIO warp mixed run against S3, prints the summary
task play:down     # delete the namespace, its volumes, and the lake bucket
```

### Failure drills (least to most disruptive)

Run these in order and let the cluster return to healthy between steps.
**Never kill `quobyte-reg-0` first.** Its initContainer runs `qbootstrap`,
which creates the cluster; every other registry ordinal joins it through
`qmkdev`.

```fish
# 1. Kill a data pod. Recovered in ~7s here, with no dropped RWX I/O.
kubectl --context=quobyte-test delete pod quobyte-data-1 -n quobyte

# 2. Kill the client on a node running a smoke pod. podKiller should evict the
#    workload pod from its stale mount instead of leaving it silently broken.
#    Find the smoke pod's node, then the client DaemonSet pod on that node:
kubectl --context=quobyte-test get pods -n quobyte -l app=quobyte-smoke -o wide
kubectl --context=quobyte-test get pods -n quobyte -o wide | grep client
kubectl --context=quobyte-test delete pod <quobyte-client-pod-on-that-node> -n quobyte

# 3. Kill a metadata pod. Paxos holds consensus on 2 of 3 replicas (~8s here).
kubectl --context=quobyte-test delete pod quobyte-meta-1 -n quobyte

# 4. Kill the bootstrap registry.
kubectl --context=quobyte-test delete pod quobyte-reg-0 -n quobyte
```

Watch recovery with `kubectl --context=quobyte-test get pods -n quobyte -w`
and cross-check the webconsole's service health view against `qmgmt`.

### MCP

Quobyte 5.x's API service serves an MCP endpoint at `/mcp` that exposes the
File Query Engine (FQE) to an LLM agent: `describe_query_schema`,
`query_files`, `preview_query`, `get_query_result`, `cancel_query`,
`show_query_id`. `.mcp.json` at the repo root registers it as `quobyte` for
Claude Code sessions launched from this directory. It points at
`localhost:7860` with Basic auth for `root`/`quobyte`, so forward the API
first:

```fish
task tunnel &   # k3s API over IAP
task mcp &      # port-forward svc/quobyte-api -> localhost:7860
claude          # from the repo root; /mcp lists the quobyte server
```

The forward runs over the IAP tunnel because Basic auth over the Gateway's
plain HTTP would send credentials across the internet. Override the credential
with `QUOBYTE_MCP_AUTH=<base64 user:pass>`.

Queries need a license that includes FQE, and the Free Edition key doesn't.
`install_quobyte.sh` imports `quobyte/license.key` if it exists (the file is
gitignored). The Free key's `feature_set` is `FREE_VERSION_2020`, readable with
the JSON-RPC `getLicense` method on `:7860/`. With it, every query returns
"Access denied"; `qmgmt query files` gives the real reason, `The File Query
Engine is not enabled for the configured license`. The MCP handshake, the tool
list and `preview_query` work regardless.

### Teardown and rebuild

`task destroy` uninstalls the Quobyte helm releases before running
`tofu destroy`, so the CSI driver's `Delete` reclaim policy removes its
dynamically provisioned PDs and nothing is orphaned. If something does leak,
`task pd:prune` deletes unattached PD CSI disks in the project. `task up`
rebuilds everything from bare VMs in one pass, smoke test included.

## Known issues

- **`chown` fails with EPERM on Quobyte mounts, even as root.** With the CSI
  driver authenticating as the `root` Quobyte user, `chown`/`chgrp` to a uid
  with no matching Quobyte user returns `Operation not permitted`, and
  everything lands owned by 0:0. `datagen` records intended ownership in
  `user.owner`/`user.project` xattrs instead; xattrs work, and FQE can query
  them.
- **quay.io's CDN drops OCI chart downloads.** `helm upgrade` from
  `oci://quay.io/quobyte/charts` sometimes fails with `failed to perform
"Fetch" ... EOF`. `install_quobyte.sh` retries three times.
- **`qmgmt` loops forever instead of failing.** Run without `-u` outside an
  API pod, it retries `Connection refused` against `localhost:7860`, then
  re-prompts `Username:` endlessly when stdin is empty. Always pass
  `-u http://quobyte-api:7860` and pipe credentials. Selecting the exec pod by
  the wrong label (`app=quobyte-webconsole`; the real label is
  `app=quobyte-web`) triggers exactly this: `root` is never created, and PVCs
  sit `Pending` with "unable to resolve user/group". `install_quobyte.sh`
  fails the install if `root` is missing.
- **API pods can hold stale registry IPs after a rolling restart.** When the
  registry pods get new IPs, the API keeps dialing the old ones and every
  request hangs until timeout. `kubectl rollout restart deploy/quobyte-api`
  clears it.
