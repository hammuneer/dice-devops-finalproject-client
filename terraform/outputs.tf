output "client_internal_ip" {
  description = "Private IP of the client VM"
  value       = google_compute_instance.client.network_interface[0].network_ip
}

output "client_external_ip" {
  description = "Public IP of the client VM"
  value       = google_compute_instance.client.network_interface[0].access_config[0].nat_ip
}

output "grafana_url" {
  description = "Grafana dashboard on the client VM"
  value       = "http://${google_compute_instance.client.network_interface[0].access_config[0].nat_ip}:${var.grafana_port}"
}

output "ssh_command" {
  description = "SSH into the client VM"
  value       = "gcloud compute ssh ${google_compute_instance.client.name} --zone ${var.zone} --project ${var.project_id}"
}
