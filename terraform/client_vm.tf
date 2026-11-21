# Look up the network created by the server repo's Terraform.
data "google_compute_network" "vpc" {
  name = var.network_name
}

data "google_compute_subnetwork" "subnet" {
  name   = var.subnet_name
  region = var.region
}

resource "google_compute_instance" "client" {
  name         = "client-vm"
  machine_type = var.machine_type
  zone         = var.zone

  # Same tags as the server, so the shared firewall rules (SSH, Grafana) apply.
  tags = ["ssh", "grafana", "app-client"]

  labels = {
    project = "dice-devops-finalproject"
    role    = "client"
  }

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.disk_size_gb
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.subnet.self_link
    network_ip = var.client_internal_ip

    # Ephemeral public IP: needed for Grafana, SSH, Docker Hub and GitHub access.
    access_config {}
  }

  metadata_startup_script = file("${path.module}/scripts/startup.sh")

  metadata = {
    enable-oslogin = "TRUE"
    # Read by the deploy pipeline to know where the server lives.
    server-internal-ip = var.server_internal_ip
  }

  service_account {
    scopes = ["logging-write", "monitoring-write"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  allow_stopping_for_update = true
}
