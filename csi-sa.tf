data "google_project" "current" {
  project_id = var.project_id
}

locals {
  node_service_account = "${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_service_account" "pd_csi" {
  account_id   = "${var.cluster_name}-pd-csi"
  display_name = "GCE PD CSI driver for ${var.cluster_name}"
}

# The driver needs permissions to create, delete, attach, and detach disks.
resource "google_project_iam_member" "pd_csi_storage" {
  project = var.project_id
  role    = "roles/compute.storageAdmin"
  member  = "serviceAccount:${google_service_account.pd_csi.email}"
}

# Impersonate node service accounts to attach disks to them.
resource "google_service_account_iam_member" "pd_csi_impersonate_nodes" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${local.node_service_account}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.pd_csi.email}"
}

# Service account key for cloud-sa.json used by deploy-driver.sh.
resource "google_service_account_key" "pd_csi" {
  service_account_id = google_service_account.pd_csi.name
}
