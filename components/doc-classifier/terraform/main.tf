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
  image_name_and_tag = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo}/${var.classifier_cloud_run_job_name}:latest"
}

# Enable APIs
# See github.com/terraform-google-modules/terraform-google-project-factory
# The modules/project_services
module "project_services" {
  source                      = "github.com/terraform-google-modules/terraform-google-project-factory.git//modules/project_services?ref=ff00ab5032e7f520eb3961f133966c6ced4fd5ee" # commit hash of version 17.0.0
  project_id                  = var.project_id
  disable_services_on_destroy = false
  disable_dependent_services  = false
  activate_apis = [
    # General container build and registry
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "documentai.googleapis.com",
    "run.googleapis.com",
    "compute.googleapis.com",
  ]

  # Provide more access to the cloudbuild service account
  activate_api_identities = [{
    "api" : "cloudbuild.googleapis.com",
    "roles" : [
      "roles/run.admin",
      # Required for Cloud Run to launch as the normal compute service account
      "roles/iam.serviceAccountUser",
    ]
    },
    {
      "api" : "pubsub.googleapis.com",
      # PubSub publish to Cloud Run
      "roles" : [
        #"roles/iam.serviceAccountUser",
        "roles/iam.serviceAccountTokenCreator",
      ],
    }
  ]
}

module "doc_classifier_account" {
  source     = "github.com/terraform-google-modules/terraform-google-service-accounts?ref=a11d4127eab9b51ec9c9afdaf51b902cd2c240d9" #commit hash of version 4.0.0
  project_id = var.project_id
  prefix     = "eks"
  names      = [local.service_account_name]
  project_roles = [
    "${var.project_id}=>roles/storage.objectUser",
    "${var.project_id}=>roles/documentai.apiUser",
  ]
  display_name = "Doc Classifier Account"
  description  = "Account used to run the document classifier jobs"
}

resource "google_cloud_run_v2_job" "docai-form-processor-job" {
  name     = var.classifier_cloud_run_job_name
  location = var.region

  depends_on = [module.gcloud_build_doc_classifier.wait]

  template {
    template {
      service_account = module.doc_classifier_account.email
      vpc_access {
        network_interfaces {
          network    = var.vpc_network_name
          subnetwork = var.serverless_connector_subnet
        }
        egress = "ALL_TRAFFIC"
      }
      containers {
        image = local.image_name_and_tag
      }
    }
  }
  lifecycle {
    ignore_changes = [
      effective_labels["goog-packaged-solution"],
      terraform_labels["goog-packaged-solution"],
      labels["goog-packaged-solution"]
    ]
  }
  deletion_protection = false
}
