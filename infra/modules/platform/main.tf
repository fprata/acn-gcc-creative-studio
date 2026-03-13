# Copyright 2025 Google LLC
# Licensed under the Apache License, Version 2.0

# --- Shared Platform Resources ---

module "network" {
  source = "../network"
  gcp_project_id = var.gcp_project_id
  gcp_region     = var.gcp_region
  resource_prefix = "cs-${var.environment}"
}

resource "google_storage_bucket" "genmedia" {
  name                        = "${var.gcp_project_id}-cs-${var.environment}-bucket"
  location                    = var.gcp_region
  uniform_bucket_level_access = true

  cors {
    origin          = ["*"]
    method          = ["GET", "PUT", "POST", "DELETE", "HEAD", "OPTIONS"]
    response_header = ["Content-Type", "Access-Control-Allow-Origin", "x-goog-resumable", "Authorization", "Origin"]
    max_age_seconds = 3600
  }
}

resource "google_service_account" "bucket_reader_sa" {
  account_id   = "cs-${var.environment}-read"
  display_name = "SA for reading GenMedia (${var.environment}) bucket"
}

resource "google_storage_bucket_iam_member" "bucket_viewer_binding" {
  bucket = google_storage_bucket.genmedia.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.bucket_reader_sa.email}"
}

resource "google_storage_bucket_iam_member" "bucket_creator_binding" {
  bucket = google_storage_bucket.genmedia.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.bucket_reader_sa.email}"
}

data "google_project" "project" {
  project_id = var.gcp_project_id
}

resource "google_compute_global_address" "default" {
  name = "cs-${var.environment}-lb-ip"
}

# --- Predictable URLs & Environment Variables ---
locals {
  actual_domain = var.domain != "" ? var.domain : "${replace(google_compute_global_address.default.address, ".", "-")}.nip.io"
  app_url = "https://${local.actual_domain}"

  backend_env_vars = merge(
    lookup(var.be_env_vars, "common", {}),
    lookup(var.be_env_vars, var.environment, {}),
    {
      "CORS_ORIGINS"           = "[\"${local.app_url}\"]"
      "GENMEDIA_BUCKET"        = google_storage_bucket.genmedia.name
      "SIGNING_SA_EMAIL"       = google_service_account.bucket_reader_sa.email
      "BACKEND_URL"            = local.app_url
      "WORKFLOWS_EXECUTOR_URL" = "${local.app_url}/api/workflows-executor"
    }
  )
}

# --- Cloud Build Repository Connection ---
resource "google_cloudbuildv2_repository" "source_repo" {
  provider          = google-beta
  name              = var.github_repo_name
  location          = var.gcp_region
  parent_connection = "projects/${var.gcp_project_id}/locations/${var.gcp_region}/connections/${var.github_conn_name}"
  remote_uri        = "https://github.com/${var.github_repo_owner}/${var.github_repo_name}.git"
}

# Postgres Database related
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "creative-studio-db-password"
  replication {
    user_managed {
      replicas {
        location = var.gcp_region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db_password.result
}

module "postgresql" {
  source      = "../postgresql"
  project_id  = var.gcp_project_id
  region      = var.gcp_region
  db_password = google_secret_manager_secret_version.db_password.secret_data
  vpc_network_id = module.network.network_id
  vpc_connection = module.network.private_vpc_connection
}

# --- Service Module Calls ---
module "backend_service" {
  source = "../cloud-run-service"

  gcp_project_id        = var.gcp_project_id
  gcp_region            = var.gcp_region
  environment           = var.environment
  service_name          = var.backend_service_name
  resource_prefix       = "cs-be"
  github_conn_name      = var.github_conn_name
  github_repo_owner     = var.github_repo_owner
  github_repo_name      = var.github_repo_name
  github_branch_name    = var.github_branch_name
  cloudbuild_yaml_path  = "backend/cloudbuild.yaml"
  included_files_glob   = ["backend/**"]
  container_env_vars    = local.backend_env_vars
  runtime_secrets       = var.backend_runtime_secrets
  custom_audiences      = var.backend_custom_audiences
  scaling_min_instances = 1
  source_repository_id  = google_cloudbuildv2_repository.source_repo.id
  cpu                   = var.be_cpu
  memory                = var.be_memory
  vpc_network_id        = module.network.network_id
  vpc_subnetwork_name   = module.network.serverless_subnetwork_name
  build_substitutions   = merge(var.be_build_substitutions,
    {
      _REGION = var.gcp_region
      _SERVICE_NAME = var.backend_service_name
    }
  )

  cloud_sql_connection_name = module.postgresql.connection_name
  db_name                   = module.postgresql.db_name
  db_user                   = module.postgresql.db_user
  db_secret_id              = google_secret_manager_secret.db_password.secret_id
  enable_cloudsql           = true
  secret_depends_on         = [google_secret_manager_secret_version.db_password]
}

module "frontend_service" {
  source = "../cloud-run-service"

  gcp_project_id        = var.gcp_project_id
  gcp_region            = var.gcp_region
  environment           = var.environment
  service_name          = var.frontend_service_name
  resource_prefix       = "cs-fe"
  github_conn_name      = var.github_conn_name
  github_repo_owner     = var.github_repo_owner
  github_repo_name      = var.github_repo_name
  github_branch_name    = var.github_branch_name
  cloudbuild_yaml_path  = "frontend/cloudbuild-run.yaml"
  included_files_glob   = ["frontend/**"]
  container_env_vars    = {
    "BACKEND_URL" = "${local.app_url}/api"
  }
  runtime_secrets       = {}
  custom_audiences      = var.frontend_custom_audiences
  scaling_min_instances = 1
  source_repository_id  = google_cloudbuildv2_repository.source_repo.id
  cpu                   = var.fe_cpu
  memory                = var.fe_memory
  vpc_network_id        = module.network.network_id
  vpc_subnetwork_name   = module.network.serverless_subnetwork_name
  build_substitutions   = merge(var.fe_build_substitutions,
    {
      _REGION = var.gcp_region
      _SERVICE_NAME = var.frontend_service_name
    }
  )

  # No database for frontend
  cloud_sql_connection_name = ""
  db_name                   = ""
  db_user                   = ""
  db_secret_id              = ""
  enable_cloudsql           = false
}

module "load_balancer" {
  source = "../load-balancer"
  gcp_project_id = var.gcp_project_id
  gcp_region     = var.gcp_region
  resource_prefix = "cs-${var.environment}"
  backend_service_id = module.backend_service.service_name
  frontend_service_id = module.frontend_service.service_name
  iap_client_id     = var.iap_client_id
  iap_client_secret = var.iap_client_secret
  actual_domain     = local.actual_domain
  global_ip_address = google_compute_global_address.default.address
}

# --- Database Migration Cloud Run Job ---
# Runs inside the VPC with access to the private Cloud SQL instance.
# Trigger with: gcloud run jobs execute cstudio-db-migrate --region=europe-west1
resource "google_cloud_run_v2_job" "db_migrate" {
  name     = "cstudio-db-migrate"
  location = var.gcp_region
  deletion_protection = false

  template {
    template {
      service_account = module.backend_service.run_sa_email

      vpc_access {
        network_interfaces {
          network    = module.network.network_id
          subnetwork = module.network.serverless_subnetwork_name
        }
        egress = "ALL_TRAFFIC"
      }

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [module.postgresql.connection_name]
        }
      }

      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello:latest"

        command = ["python", "-m", "bootstrap.bootstrap"]
        args    = [var.gcp_project_id, var.gcp_region, google_storage_bucket.genmedia.name, module.postgresql.connection_name]

        env {
          name  = "INSTANCE_CONNECTION_NAME"
          value = module.postgresql.connection_name
        }
        env {
          name  = "DB_HOST"
          value = "/cloudsql/${module.postgresql.connection_name}"
        }
        env {
          name  = "DB_NAME"
          value = module.postgresql.db_name
        }
        env {
          name  = "DB_USER"
          value = module.postgresql.db_user
        }
        env {
          name = "DB_PASS"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.db_password.secret_id
              version = "latest"
            }
          }
        }
        env {
          name  = "USE_CLOUD_SQL_AUTH_PROXY"
          value = "false"
        }
        env {
          name  = "PYTHONPATH"
          value = "/app"
        }
        env {
          name  = "PROJECT_ID"
          value = var.gcp_project_id
        }
        env {
          name  = "GENMEDIA_BUCKET"
          value = google_storage_bucket.genmedia.name
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "2Gi"
          }
        }
      }

      timeout = "600s"
      max_retries = 0
    }
  }

  lifecycle {
    ignore_changes = [template[0].template[0].containers[0].image]
  }
}

module "frontend_secrets" {
  source = "../secret-manager"

  gcp_project_id    = var.gcp_project_id
  secret_names      = var.frontend_secrets
  accessor_sa_email = module.frontend_service.trigger_sa_email
}

module "backend_secrets" {
  source = "../secret-manager"

  gcp_project_id    = var.gcp_project_id
  secret_names      = var.backend_secrets
  accessor_sa_email = module.backend_service.trigger_sa_email
}
