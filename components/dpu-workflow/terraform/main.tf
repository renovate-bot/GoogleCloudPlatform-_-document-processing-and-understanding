# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

locals {
  env_name          = "dpu-composer"
  composer_sa_roles = [for role in var.composer_sa_roles : "${module.project_services.project_id}=>${role}"]
  dpu_label = {
    goog-packaged-solution : "eks-solution"
  }
}

module "project_services" {
  source                      = "github.com/terraform-google-modules/terraform-google-project-factory.git//modules/project_services?ref=ff00ab5032e7f520eb3961f133966c6ced4fd5ee" # commit hash of version 17.0.0
  project_id                  = var.project_id
  disable_services_on_destroy = false
  disable_dependent_services  = false
  activate_apis               = var.required_apis
  activate_api_identities = [{
    "api" : "composer.googleapis.com",
    "roles" : [
      "roles/composer.ServiceAgentV2Ext",
      "roles/composer.serviceAgent",
    ]
  }]
}

resource "google_project_default_service_accounts" "disable_default_service_accounts" {
  project = var.project_id
  action  = "DISABLE"
}

module "composer_service_account" {
  source = "github.com/terraform-google-modules/terraform-google-service-accounts?ref=a11d4127eab9b51ec9c9afdaf51b902cd2c240d9" #commit hash of version 4.0.0

  project_id = module.project_services.project_id
  prefix     = local.env_name
  names = [
    "runner"
  ]
  project_roles = local.composer_sa_roles
}

resource "google_compute_subnetwork" "composer_connector_subnet" {
  name                     = var.composer_connector_subnet
  ip_cidr_range            = var.composer_cidr.subnet_primary
  region                   = var.region
  network                  = var.vpc_network_name
  private_ip_google_access = true
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_composer_environment" "composer_env" {
  project = module.project_services.project_id
  name    = local.env_name
  region  = var.region
  labels  = local.dpu_label

  config {
    enable_private_environment = true
    enable_private_builds_only = false
    software_config {
      image_version = var.composer_version
      env_variables = var.composer_env_variables
      pypi_packages = var.composer_additional_pypi_packages
    }
    workloads_config {
      scheduler {
        cpu        = var.composer_scheduler_cpu
        memory_gb  = var.composer_scheduler_memory
        storage_gb = var.composer_scheduler_storage
        count      = var.composer_scheduler_count
      }
      web_server {
        cpu        = var.composer_web_server_cpu
        memory_gb  = var.composer_web_server_memory
        storage_gb = var.composer_web_server_storage
      }
      worker {
        cpu        = var.composer_worker_cpu
        memory_gb  = var.composer_worker_memory
        storage_gb = var.composer_worker_storage
        min_count  = var.composer_worker_min_count
        max_count  = var.composer_worker_max_count
      }
    }
    environment_size = var.composer_environment_size
    node_config {
      network         = var.vpc_network_id
      subnetwork      = google_compute_subnetwork.composer_connector_subnet.id
      service_account = module.composer_service_account.email
    }
  }
}

resource "google_storage_bucket_object" "workflow_orchestrator_dag" {
  for_each       = fileset("${path.module}/../src", "**/*.py")
  name           = "dags/${each.value}"
  bucket         = google_composer_environment.composer_env.storage_config[0].bucket
  source         = "${path.module}/../src/${each.value}"
  detect_md5hash = "true"
}
