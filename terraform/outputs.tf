output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.primary.name
}

output "cluster_location" {
  description = "GKE cluster zone."
  value       = google_container_cluster.primary.location
}

output "get_credentials_command" {
  description = "Run this to configure kubectl against the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
}

output "artifact_registry_url" {
  description = "Base URL to tag/push the app image to."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}"
}

output "model_bucket" {
  description = "GCS bucket for model weights (gs:// URI)."
  value       = "gs://${google_storage_bucket.models.name}"
}

output "app_service_account_email" {
  description = "Google SA to annotate the Kubernetes ServiceAccount with."
  value       = google_service_account.app.email
}

output "ksa_annotation_command" {
  description = "Wire the Kubernetes ServiceAccount to the Google SA (Workload Identity)."
  value       = "kubectl annotate serviceaccount ${var.k8s_service_account} -n ${var.k8s_namespace} iam.gke.io/gcp-service-account=${google_service_account.app.email}"
}
