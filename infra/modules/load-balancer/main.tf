# Copyright 2025 Google LLC
# Licensed under the Apache License, Version 2.0

variable "gcp_project_id" { type = string }
variable "gcp_region"     { type = string }
variable "resource_prefix" { type = string }
variable "backend_service_id" { type = string }
variable "frontend_service_id" { type = string }
variable "iap_client_id" { type = string }
variable "iap_client_secret" { type = string }

resource "google_compute_region_network_endpoint_group" "backend_neg" {
  name                  = "${var.resource_prefix}-be-neg"
  region                = var.gcp_region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = var.backend_service_id
  }
}

resource "google_compute_region_network_endpoint_group" "frontend_neg" {
  name                  = "${var.resource_prefix}-fe-neg"
  region                = var.gcp_region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = var.frontend_service_id
  }
}

resource "google_compute_backend_service" "backend" {
  name        = "${var.resource_prefix}-be-backend"
  protocol    = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  
  backend {
    group = google_compute_region_network_endpoint_group.backend_neg.id
  }

  iap {
    enabled              = true
    oauth2_client_id     = var.iap_client_id
    oauth2_client_secret = var.iap_client_secret
  }
}

resource "google_compute_backend_service" "frontend" {
  name        = "${var.resource_prefix}-fe-backend"
  protocol    = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  
  backend {
    group = google_compute_region_network_endpoint_group.frontend_neg.id
  }

  iap {
    enabled              = true
    oauth2_client_id     = var.iap_client_id
    oauth2_client_secret = var.iap_client_secret
  }
}

resource "google_compute_url_map" "default" {
  name            = "${var.resource_prefix}-lb"
  default_service = google_compute_backend_service.frontend.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "allpaths"
  }

  path_matcher {
    name            = "allpaths"
    default_service = google_compute_backend_service.frontend.id

    path_rule {
      paths   = ["/api/*"]
      service = google_compute_backend_service.backend.id
    }
  }
}

variable "global_ip_address" { type = string }
variable "actual_domain" { type = string }

resource "google_compute_managed_ssl_certificate" "default" {
  name = "${var.resource_prefix}-cert"
  managed {
    domains = [var.actual_domain]
  }
}

resource "google_compute_target_https_proxy" "default" {
  name             = "${var.resource_prefix}-https-proxy"
  url_map          = google_compute_url_map.default.id
  ssl_certificates = [google_compute_managed_ssl_certificate.default.id]
}

resource "google_compute_global_forwarding_rule" "default" {
  name                  = "${var.resource_prefix}-lb-forwarding-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.default.id
  ip_address            = var.global_ip_address
}

output "load_balancer_ip" {
  value = google_compute_global_forwarding_rule.default.ip_address
}
output "actual_domain" { value = var.actual_domain }
