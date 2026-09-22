variable "project_id" {
  description = "The GCP Project ID where resources will be provisioned."
  type        = string
  default     = "terraform-sandbox-430820"
}

variable "region" {
  description = "The GCP region to provision the subnet in."
  type        = string
  default     = "us-east1"
}

variable "zone" {
  description = "Single GCP zone for every instance (zonal deployment for throwaway sandbox)."
  type        = string
  default     = "us-east1-b"
}

variable "cluster_name" {
  description = "Prefix for every named resource."
  type        = string
  default     = "quobyte-test"
}

variable "num_worker_nodes" {
  description = "Number of k3s agent worker nodes. Must be at least 3 to satisfy Quobyte podAntiAffinity."
  type        = number
  default     = 3
}

variable "control_plane_machine_type" {
  description = "Machine type for the k3s server node."
  type        = string
  default     = "e2-medium"
}

variable "node_machine_type" {
  description = "Machine type for each k3s agent worker node. e2-highmem-2 (16 GB) because Quobyte 5.1's S3 gateway needs a 10 GiB object cache, which an 8 GB e2-standard-2 can't fit. Same 2 vCPUs, so no quota change."
  type        = string
  default     = "e2-highmem-2"
}

variable "node_machine_type_overrides" {
  description = "Sparse per-node machine_type override, keyed by node index as string."
  type        = map(string)
  default     = {}
}

variable "boot_image" {
  description = "Boot disk image for control plane and worker nodes."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB for every instance. 50GB pd-standard comfortably holds k3s and container images."
  type        = number
  default     = 50
}

variable "allowed_source_ranges" {
  description = "CIDR allowlist for the Cilium Gateway (80/443/4245/8080) firewall rule."
  type        = list(string)
}

variable "subnet_cidr" {
  description = "CIDR range for the custom subnet. Clear of k3s pod (10.244.0.0/16) and service (10.96.0.0/12) CIDRs."
  type        = string
  default     = "10.10.0.0/24"
}

variable "k3s_channel" {
  description = "k3s release channel. Pinned to v1.34 because quobyte-cluster Chart.yaml caps at 1.35-0."
  type        = string
  default     = "v1.34"
}

variable "gitops_repo_url" {
  description = "Git URL of this repo — cloned by VM startup scripts at boot."
  type        = string
  default     = "https://github.com/IanEff/quobyte-test.git"
}
