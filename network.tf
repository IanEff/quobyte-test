resource "google_compute_network" "main" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "${var.cluster_name}-subnet"
  network       = google_compute_network.main.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

locals {
  # Google Cloud fixed IAP TCP forwarding range
  iap_source_range = "35.235.240.0/20"
}

resource "google_compute_firewall" "allow_ssh" {
  name          = "${var.cluster_name}-allow-ssh"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = [local.iap_source_range]
  target_tags   = ["${var.cluster_name}-node"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "allow_k3s_api" {
  name          = "${var.cluster_name}-allow-k3s-api"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = [local.iap_source_range]
  target_tags   = ["${var.cluster_name}-control-plane"]

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }
}

resource "google_compute_firewall" "allow_gateway" {
  name          = "${var.cluster_name}-allow-gateway"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = var.allowed_source_ranges
  target_tags   = ["${var.cluster_name}-control-plane"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "4245", "8080"]
  }
}

resource "google_compute_firewall" "allow_internal" {
  name          = "${var.cluster_name}-allow-internal"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = [var.subnet_cidr]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}
