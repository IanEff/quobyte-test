resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "google_compute_address" "control_plane_internal" {
  name         = "${var.cluster_name}-control-plane-internal"
  region       = var.region
  subnetwork   = google_compute_subnetwork.main.id
  address_type = "INTERNAL"
}

resource "google_compute_address" "control_plane_external" {
  name         = "${var.cluster_name}-control-plane-external"
  region       = var.region
  address_type = "EXTERNAL"
}

locals {
  control_plane_startup_script = templatefile("${path.module}/provisioning/scripts/control-plane-bootstrap.sh.tpl", {
    control_plane_internal_ip = google_compute_address.control_plane_internal.address
    control_plane_external_ip = google_compute_address.control_plane_external.address
    k3s_token                 = random_password.k3s_token.result
    k3s_channel               = var.k3s_channel
    gitops_repo_url           = var.gitops_repo_url
    pd_csi_sa_key_b64         = google_service_account_key.pd_csi.private_key
  })

  node_startup_script = templatefile("${path.module}/provisioning/scripts/node-bootstrap.sh.tpl", {
    control_plane_internal_ip = google_compute_address.control_plane_internal.address
    k3s_token                 = random_password.k3s_token.result
    k3s_channel               = var.k3s_channel
    gitops_repo_url           = var.gitops_repo_url
  })
}

resource "google_compute_instance" "control_plane" {
  name         = "${var.cluster_name}-control-plane"
  machine_type = var.control_plane_machine_type
  zone         = var.zone
  tags         = ["${var.cluster_name}-node", "${var.cluster_name}-control-plane"]

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.boot_disk_size_gb
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = google_compute_address.control_plane_internal.address
    access_config {
      nat_ip = google_compute_address.control_plane_external.address
    }
  }

  metadata_startup_script = local.control_plane_startup_script

  metadata = {
    enable-oslogin = "TRUE"
  }

  scheduling {
    preemptible       = false
    automatic_restart = true
  }
}

resource "google_compute_instance" "node" {
  count        = var.num_worker_nodes
  name         = "${var.cluster_name}-node-${count.index + 1}"
  machine_type = lookup(var.node_machine_type_overrides, tostring(count.index), var.node_machine_type)
  zone         = var.zone
  tags         = ["${var.cluster_name}-node"]

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.boot_disk_size_gb
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    access_config {} # Ephemeral public IP
  }

  metadata_startup_script = local.node_startup_script

  metadata = {
    enable-oslogin = "TRUE"
  }

  scheduling {
    preemptible       = false
    automatic_restart = true
  }

  depends_on = [google_compute_instance.control_plane]
}
