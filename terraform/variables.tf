variable "project_id" {
  description = "GCP project ID that holds all resources"
  type        = string
}

variable "region" {
  description = "GCP region (must match the server stack)"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the VM"
  type        = string
  default     = "us-central1-a"
}

# The VPC and subnet are created by the server repo's Terraform; we only look them up.
variable "network_name" {
  description = "Existing VPC created by the server stack"
  type        = string
  default     = "devops-vpc"
}

variable "subnet_name" {
  description = "Existing subnet created by the server stack"
  type        = string
  default     = "devops-subnet"
}

variable "client_internal_ip" {
  description = "Fixed private IP of the client VM"
  type        = string
  default     = "10.10.1.20"
}

variable "server_internal_ip" {
  description = "Private IP of the server VM (output of the server stack)"
  type        = string
  default     = "10.10.1.10"
}

variable "machine_type" {
  description = "VM size"
  type        = string
  default     = "e2-micro"
}

variable "disk_size_gb" {
  description = "Boot disk size. Free tier includes 30 GB of standard persistent disk in total"
  type        = number
  default     = 10
}

variable "image" {
  description = "Boot image for the VM"
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "grafana_port" {
  description = "Port where Grafana is exposed"
  type        = number
  default     = 3020
}
