# quobyte-test

Throwaway GCP test sandbox running Quobyte Free Edition on raw-VM k3s to evaluate out-of-tree GCE PD CSI volume dynamic provisioning, multi-node RWX file storage, Cilium tunnel mode networking, Hubble observability, and S3 Gateway capabilities.

## Architecture

- **Infrastructure:** OpenTofu on Google Cloud Platform
- **Topology:** 1× `e2-medium` control-plane + 3× `e2-standard-2` workers (total 8 E2 vCPUs) in `us-east1-b`
- **Disks:** 100% `pd-standard` boot and CSI storage devices (0 GB SSD quota used)
- **Kubernetes:** k3s release pinned to `v1.34` (`v1.34.10+k3s1`)
- **Networking:** Cilium 1.19 in Geneve/VXLAN tunnel mode + hostNetwork Gateway API + Hubble Relay/UI
- **Storage:** Out-of-tree GCE PD CSI driver + Quobyte Free Edition Helm charts

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

`qmgmt` runs from inside any Quobyte pod (they all share the server image).
Write commands need real piped credentials — see **Known issues** below.

```bash
QMGMT_POD=$(kubectl --context=quobyte-test get pods -n quobyte -l app=quobyte-webconsole -o jsonpath='{.items[0].metadata.name}')

# read-only, no auth needed
kubectl --context=quobyte-test exec -it "$QMGMT_POD" -n quobyte -- qmgmt tenant list
kubectl --context=quobyte-test exec -it "$QMGMT_POD" -n quobyte -- qmgmt user config list
```

### S3 Gateway demo

Path-style addressing works, which sidesteps the wildcard-DNS problem that
subdomain-style bucket addressing (`<bucket>.s3.quobyte-test.lab`) would
otherwise need. First mint an access key (root has none by default):

```bash
kubectl --context=quobyte-test exec -it "$QMGMT_POD" -n quobyte -- \
  qmgmt accesskey create --tenant="My Tenant" GENERAL_ACCESS_KEY root
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

### Teardown / rebuild

`task destroy` uninstalls the Quobyte helm releases first (so the CSI
driver's `Delete` reclaim policy cleans up its dynamically-provisioned PDs)
before running `tofu destroy` — nothing should orphan. `task up` rebuilds
everything from bare VMs in one shot, including re-running the smoke test.

## Known issues

- **`qmgmt` write commands hang without a real TTY.** Any write command
  (`user config add`, `whoami`, etc.) run non-interactively doesn't fail
  cleanly on a rejected/empty answer — it just re-prompts `Username:` forever
  instead of erroring out. `install_quobyte.sh` defends against this with a
  piped-stdin, `timeout`-wrapped exec, but if you're running `qmgmt` by hand,
  always pipe real credentials through a foreground `kubectl exec -i`. Read-only
  commands (`tenant list`, etc.) are unaffected — they work with zero auth.
  Open question, not filed upstream: is the write/read auth asymmetry
  intentional Free Edition posture, or an artifact of the empty bootstrap user
  table?
