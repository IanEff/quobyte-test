# quobyte-test lifecycle wrapper

CLUSTER_NAME := "quobyte-test"
PROJECT_ID := `tofu output -raw project_id 2>/dev/null || gcloud config get-value project 2>/dev/null || echo "terraform-sandbox-430820"`
ZONE := `tofu output -raw zone 2>/dev/null || echo "us-east1-b"`
REGION := `tofu output -raw region 2>/dev/null || echo "us-east1"`

default:
    @just --list

fmt:
    tofu fmt -recursive

init:
    tofu init

validate: init
    tofu validate

plan: init
    tofu plan

apply: init
    tofu apply -auto-approve

up: apply credentials hosts
    @echo ""
    @echo "Cluster is up! Start the background IAP tunnel for kubectl access:"
    @echo "  just tunnel &"
    @echo "Verify nodes:"
    @echo "  kubectl --context={{CLUSTER_NAME}} get nodes -o wide"

destroy: init
    tofu destroy -auto-approve
    -just hosts-remove
    -just credentials-remove

credentials:
    python3 provisioning/scripts/fetch_kubeconfig.py add

credentials-remove:
    python3 provisioning/scripts/fetch_kubeconfig.py remove

hosts:
    sudo python3 provisioning/scripts/manage_hosts.py add $(tofu output -raw control_plane_external_ip)

hosts-remove:
    sudo python3 provisioning/scripts/manage_hosts.py remove

# SSH to control-plane or node-1/2/3 via IAP
ssh TARGET="control-plane":
    gcloud compute ssh {{CLUSTER_NAME}}-{{TARGET}} --zone={{ZONE}} --project={{PROJECT_ID}} --tunnel-through-iap

# Open local IAP port forward to k3s API on 127.0.0.1:6443
tunnel:
    gcloud compute start-iap-tunnel {{CLUSTER_NAME}}-control-plane 6443 --local-host-port=localhost:6443 --zone={{ZONE}} --project={{PROJECT_ID}}
