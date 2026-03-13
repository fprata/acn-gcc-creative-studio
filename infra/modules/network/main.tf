# Copyright 2025 Google LLC
# Licensed under the Apache License, Version 2.0

variable "gcp_project_id" { type = string }
variable "gcp_region"     { type = string }
variable "resource_prefix" { type = string }

resource "google_project_service" "compute" {
  project = var.gcp_project_id
  service = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "servicenetworking" {
  project = var.gcp_project_id
  service = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "vpc_network" {
  project                 = var.gcp_project_id
  name                    = "${var.resource_prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute]
}

resource "google_compute_subnetwork" "serverless_subnet" {
  project       = var.gcp_project_id
  name          = "${var.resource_prefix}-serverless-subnet"
  ip_cidr_range = "10.0.1.0/28"
  region        = var.gcp_region
  network       = google_compute_network.vpc_network.id

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_global_address" "private_ip_address" {
  project       = var.gcp_project_id
  name          = "${var.resource_prefix}-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc_network.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
  depends_on              = [google_project_service.servicenetworking]
}

resource "google_compute_router" "router" {
  name    = "${var.resource_prefix}-router"
  region  = var.gcp_region
  network = google_compute_network.vpc_network.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.resource_prefix}-nat"
  router                             = google_compute_router.router.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

output "network_id" {
  value = google_compute_network.vpc_network.id
}

output "network_name" {
  value = google_compute_network.vpc_network.name
}

output "serverless_subnetwork_name" {
  value = google_compute_subnetwork.serverless_subnet.name
}

output "private_vpc_connection" {
  value = google_service_networking_connection.private_vpc_connection.id
}
