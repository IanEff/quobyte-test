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
just init
just plan

# 2. Deploy infrastructure and fetch credentials
just up

# 3. Open background IAP tunnel for kubectl
just tunnel &

# 4. Verify nodes
kubectl --context=quobyte-test get nodes -o wide

# 5. Teardown
just destroy
```

## Endpoints

After running `just hosts` (or accessing via control plane external IP):
- **Quobyte Webconsole:** `http://quobyte.quobyte-test.lab:8080`
- **Hubble UI:** `http://hubble.quobyte-test.lab:8080`
- **S3 Gateway:** `http://s3.quobyte-test.lab:8080`
