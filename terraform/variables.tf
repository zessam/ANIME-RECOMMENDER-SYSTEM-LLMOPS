variable "project_id" {
  description = "GCP project ID to deploy into."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources (Artifact Registry, bucket, subnet)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the (zonal) GKE cluster and its node pools. Must have the chosen GPU available."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster (also used as a prefix for network/SA names)."
  type        = string
  default     = "anime-rec-cluster"
}

variable "artifact_repo_name" {
  description = "Artifact Registry Docker repository ID for the app image."
  type        = string
  default     = "anime-rec"
}

variable "model_bucket_name" {
  description = "Globally-unique GCS bucket for model weights. Leave empty to default to <project_id>-anime-models."
  type        = string
  default     = ""
}

variable "app_machine_type" {
  description = "Machine type for the app node pool (Streamlit + pipeline). e2-standard-2 gives ~1930m allocatable CPU (vs ~940m on shared-core e2-medium), enough for the app plus light monitoring."
  type        = string
  default     = "e2-standard-2"
}

variable "serve_machine_type" {
  description = "Machine type for the vLLM CPU serving pool. e2-highmem-4 (4 vCPU / 32GB) gives ~28GB allocatable — comfortable for a 3B model on CPU (needs ~13-15GB) with no OOM risk — while using only 4 vCPU of the free-tier quota."
  type        = string
  default     = "e2-highmem-4"
}

variable "master_authorized_cidrs" {
  description = "CIDRs allowed to reach the GKE control-plane endpoint. Empty = allow all (needed for GitHub-hosted runners). Set to your office/VPN CIDRs to lock it down."
  type        = list(string)
  default     = []
}

variable "k8s_namespace" {
  description = "Kubernetes namespace the vLLM/app workloads run in (for Workload Identity binding)."
  type        = string
  default     = "default"
}

variable "k8s_service_account" {
  description = "Kubernetes ServiceAccount name the vLLM/app pods use (for Workload Identity binding)."
  type        = string
  default     = "anime-sa"
}
