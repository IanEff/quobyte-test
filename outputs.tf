output "project_id" {
  description = "GCP Project ID."
  value       = var.project_id
}

output "region" {
  description = "GCP region."
  value       = var.region
}

output "zone" {
  description = "GCP zone."
  value       = var.zone
}

output "cluster_name" {
  description = "Cluster name prefix."
  value       = var.cluster_name
}

output "control_plane_internal_ip" {
  description = "Internal IP of the control plane instance."
  value       = google_compute_address.control_plane_internal.address
}

output "control_plane_external_ip" {
  description = "External IP of the control plane instance."
  value       = google_compute_address.control_plane_external.address
}

output "worker_internal_ips" {
  description = "Internal IPs of the worker nodes."
  value       = [for instance in google_compute_instance.node : instance.network_interface[0].network_ip]
}

output "pd_csi_sa_key" {
  description = "Base64 service-account key for the GCE PD CSI driver. `tofu output -raw pd_csi_sa_key | base64 -d > cloud-sa.json`."
  value       = google_service_account_key.pd_csi.private_key
  sensitive   = true
}

output "ssh_control_plane_command" {
  description = "gcloud command to SSH into the control plane via IAP."
  value       = "gcloud compute ssh ${google_compute_instance.control_plane.name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap"
}
