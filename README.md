# quobyte-test

Throwaway GCP test sandbox running Quobyte Free Edition on raw-VM k3s to evaluate out-of-tree GCE PD CSI volume dynamic provisioning, multi-node RWX file storage, Cilium tunnel mode networking, Hubble observability, and S3 Gateway capabilities.

## Architecture

- **Infrastructure:** OpenTofu on Google Cloud Platform
- **Topology:** 1× `e2-medium` control-plane + 3× `e2-standard-2` workers (total 8 E2 vCPUs) in `us-east1-b`
- **Disks:** 100% `pd-standard` boot and CSI storage devices (0 GB SSD quota used)
- **Kubernetes:** k3s channel `v1.34` (latest patch). This is the ceiling: `quobyte-cluster` chart 0.3.0 caps k8s below 1.35
- **Networking:** Cilium 1.20.2 in VXLAN tunnel mode + hostNetwork Gateway API (CRDs v1.6.1) + Hubble Relay/UI
- **Storage:** Out-of-tree GCE PD CSI driver + Quobyte 5.1 (server and client images pinned by digest). Charts: `quobyte-cluster` 0.3.0 (legacy helm repo), `quobyte-client` 0.3.8 and `quobyte-csi` 2.4.0 (OCI, `quay.io/quobyte/charts`)

Why `quobyte-cluster` stays on 0.3.0: the newer OCI 1.0.2 chart moves data and
metadata devices from PVCs to hostPath disks on the node, which would mean
redesigning this rig's PD-CSI device model. 0.3.0 still runs the 5.1 image fine.

## Quickstart

```bash
# 1. Initialize and review plan
task init
task plan

# 2. Deploy infrastructure, fetch credentials, and bring up the full
#    Quobyte layer (helm charts, qmgmt bootstrap, gateway + smoke manifests)
task up

# 3. Open background IAP tunnel for kubectl
task tunnel &

# 4. Verify nodes
kubectl --context=quobyte-test get nodes -o wide

# 5. Teardown (uninstalls Quobyte helm releases first, so CSI-provisioned
#    PDs get reclaimed instead of orphaning before the VMs are destroyed)
task destroy
```

Run `task --list` for the full set of tasks, including `task quobyte:up` /
`task quobyte:down` to install or tear down just the Quobyte layer on an
already-running cluster.

## Endpoints

`task up` runs `task hosts` for you, which writes these hostnames into
`/etc/hosts` pointing at the control-plane's external IP. They're reachable
**directly over the internet** (the Gateway listens on the control-plane's
`hostNetwork`, and `network.tf`'s `allow-gateway` firewall rule opens ports
80/443/4245/8080 to your detected IP in `terraform.tfvars`) — you do **not**
need `task tunnel` running to reach any of these, only for `kubectl`/`helm`
against port 6443, which stays IAP-only.

- **Quobyte Webconsole:** `http://quobyte.quobyte-test.lab:8080` — login `root` / `quobyte`
- **Hubble UI:** `http://hubble.quobyte-test.lab`
- **S3 Gateway:** `http://s3.quobyte-test.lab` (path-style addressing — see below)

## Usage — playing with the system

### Credentials

Everything (webconsole, `qmgmt`, the CSI driver's provisioner secret) uses
the single bootstrap superuser `install_quobyte.sh` creates:

```
username: root
password: quobyte
tenant:   My Tenant
```

### Check cluster + Quobyte health

```bash
kubectl --context=quobyte-test get nodes -o wide
kubectl --context=quobyte-test get pods -n quobyte -o wide
kubectl --context=quobyte-test get pods -n quobyte -l app=quobyte-smoke -o wide   # RWX smoke deployment
```

### Prove RWX (ReadWriteMany) works

`task up` already applies `quobyte/smoke/rwx-smoke.yaml` — a 2-replica
Deployment, spread across nodes via `podAntiAffinity`, sharing one PVC. Each
replica writes its own timestamped file and lists everything it can see; if
both pods show both files, cross-node RWX is proven live:

```bash
kubectl --context=quobyte-test logs -n quobyte -l app=quobyte-smoke --tail=5 --prefix
```

You should see each pod's log tail listing *both* pods' `.txt` files under
`/mnt/quobyte/`. Cross-check in the webconsole too — the `quobyte-smoke` PVC
shows up as a registered volume there.

### Exercise `qmgmt` directly

`qmgmt` ships in every Quobyte pod (they all share the server image), but it's
an API client that defaults to `localhost:7860`, so outside an API pod you have
to point it at the `quobyte-api` Service with `-u`. It prompts for a login, so
pipe credentials in (see **Known issues**):

```bash
QMGMT_POD=$(kubectl --context=quobyte-test get pods -n quobyte -l app=quobyte-web -o name | head -1)
qm() { printf 'root\nquobyte\n' | kubectl --context=quobyte-test exec -i "$QMGMT_POD" -n quobyte -- qmgmt -u http://quobyte-api:7860 "$@"; }

qm tenant list
qm user config list
qm volume list
```

### S3 Gateway demo

**Currently disabled** (`s3.enabled: false` in `values-cluster.yaml`). On
Quobyte 5.1 the S3 gateway defaults to a 10 GiB object cache and crash-loops
on 8 GB nodes ("Configured object cache size is too large"). Re-enable it on
bigger workers. The steps below worked on 4.9.

Path-style addressing works, which sidesteps the wildcard-DNS problem that
subdomain-style bucket addressing (`<bucket>.s3.quobyte-test.lab`) would
otherwise need. First mint an access key (root has none by default):

```bash
qm accesskey create --tenant="My Tenant" GENERAL_ACCESS_KEY root
# -> prints an access key + secret key, capture both
```

Then, from your laptop, point `aws-cli` at the gateway. It defaults to
virtual-hosted-style addressing (`<bucket>.s3.quobyte-test.lab`), which won't
resolve — force path-style once, globally or per-command:

```bash
export AWS_ACCESS_KEY_ID=<from above>
export AWS_SECRET_ACCESS_KEY=<from above>
aws configure set default.s3.addressing_style path   # one-time, or add --endpoint-url + this per call

aws --endpoint-url http://s3.quobyte-test.lab s3 mb s3://demo-bucket
aws --endpoint-url http://s3.quobyte-test.lab s3 cp README.md s3://demo-bucket/
aws --endpoint-url http://s3.quobyte-test.lab s3 ls s3://demo-bucket/
```

Bucket creation, PUT, GET, and listing all round-trip HTTP 200 — verified
2026-08-17.

### Failure drills (most to least destructive — run in this order)

Quobyte's own docs frame this as quorum/self-healing behavior; each step is
more disruptive than the last, so let the cluster settle back to healthy
between them. **Never kill `quobyte-reg-0` first** — its initContainer runs
`qbootstrap` (creates the cluster); every other registry ordinal just joins
it via `qmkdev`.

```bash
# 1. Kill a data pod — watch it recover (~7s observed) with zero dropped RWX I/O
kubectl --context=quobyte-test delete pod quobyte-data-1 -n quobyte

# 2. Kill the client on a node running one of the smoke-app pods — podKiller
#    should force that workload pod off its now-stale mount rather than
#    leaving it silently broken. First find which node a smoke pod is on,
#    then find and delete the client pod on that same node (client ships as
#    a DaemonSet — list its pods to confirm the exact label/name on this
#    cluster before deleting):
kubectl --context=quobyte-test get pods -n quobyte -o wide | grep client
kubectl --context=quobyte-test get pods -n quobyte -l app=quobyte-smoke -o wide   # note which node
kubectl --context=quobyte-test delete pod <quobyte-client-pod-on-that-node> -n quobyte

# 3. Kill a metadata pod — Paxos should hold consensus on 2/3 replicas (~8s observed)
kubectl --context=quobyte-test delete pod quobyte-meta-1 -n quobyte

# 4. LAST: kill the bootstrap registry — the most interesting failure mode
kubectl --context=quobyte-test delete pod quobyte-reg-0 -n quobyte
```

Watch recovery with `kubectl get pods -n quobyte -w` and cross-check the
webconsole's service health view alongside `qmgmt` output.

### Ask the cluster questions via MCP

Quobyte 5.x's API service serves an MCP endpoint at `/mcp` that exposes the
File Query Engine to an LLM agent (`describe_query_schema`, `query_files`,
`preview_query`, `get_query_result`, `cancel_query`, `show_query_id`).
`.mcp.json` at the repo root registers it as `quobyte` for Claude Code, only
when it's launched from this directory. It points at `localhost:7860` with
Basic auth for `root`/`quobyte`, so the API has to be forwarded first:

```bash
task tunnel &   # k3s API over IAP
task mcp &      # port-forward svc/quobyte-api -> localhost:7860
claude          # from the repo root; /mcp shows the quobyte server
```

The forward goes over the IAP tunnel rather than the public Gateway on
purpose: Basic auth over the Gateway's plain HTTP would put credentials on
the internet. Override the credential with `QUOBYTE_MCP_AUTH=<base64 user:pass>`.
**Queries need a license.** Unlicensed, every query comes back "Access denied".
`qmgmt query files` gives the real reason: `The File Query Engine is not
enabled for the configured license`. The MCP handshake, tool list and
`preview_query` all work without a license. To run real queries, get a key
(free registration at quobyte.com/register-free covers Free and Enterprise
keys) and import it:

```bash
qm license import <key-file-or-key>   # see `qmgmt license -h`; qm() is defined above
```

### Teardown / rebuild

`task destroy` uninstalls the Quobyte helm releases first (so the CSI
driver's `Delete` reclaim policy cleans up its dynamically-provisioned PDs)
before running `tofu destroy` — nothing should orphan. `task up` rebuilds
everything from bare VMs in one shot, including re-running the smoke test.

## Known issues

- **`qmgmt` loops forever instead of failing.** Run without `-u` outside an
  API pod, it retries `Connection refused` against `localhost:7860` and then
  re-prompts `Username:` endlessly when stdin is empty. Always pass
  `-u http://quobyte-api:7860` and pipe credentials. This bit the original
  bootstrap: it exec'd into a pod selected by the wrong label
  (`app=quobyte-webconsole`; the real label is `app=quobyte-web`), never
  created `root`, and the smoke PVC sat `Pending` with "unable to resolve
  user/group". `install_quobyte.sh` now fails the install if `root` is missing.
- **API pods can hold stale registry IPs after a rolling restart.** When the
  registry pods get new IPs, the API keeps dialing the old ones and every
  request hangs until timeout. `kubectl rollout restart deploy/quobyte-api`
  clears it.
