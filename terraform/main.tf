locals {
  model_bucket_name = var.model_bucket_name != "" ? var.model_bucket_name : "${var.project_id}-anime-models"

  labels = {
    app        = "anime-recommender"
    managed-by = "terraform"
  }

  # APIs required for the whole stack.
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

# ---------------------------------------------------------------------------
# Enable required APIs
# ---------------------------------------------------------------------------
resource "google_project_service" "services" {
  for_each = toset(local.services)

  project = var.project_id
  service = each.value

  # Keep APIs enabled on `terraform destroy` — disabling them is slow and can
  # break other resources during teardown.
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Network (VPC-native cluster needs a custom subnet with secondary ranges)
# ---------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  #checkov:skip=CKV2_GCP_18:Firewall rules for the cluster are managed automatically by GKE on this custom VPC.
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.services]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.10.0.0/16"

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }

  # Required for private nodes to reach Google APIs without public IPs.
  private_ip_google_access = true
}

# ---------------------------------------------------------------------------
# Cloud NAT — outbound internet for private nodes (pull images, download model)
# ---------------------------------------------------------------------------
resource "google_compute_router" "router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------------------------------------------------------------------
# Service account used by the GKE nodes (least privilege)
# ---------------------------------------------------------------------------
resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE node service account for ${var.cluster_name}"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader", # pull the app image
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# ---------------------------------------------------------------------------
# GKE cluster (zonal, VPC-native, Workload Identity enabled)
# ---------------------------------------------------------------------------
#tfsec:ignore:google-gke-enforce-pod-security-policy PSP was removed in Kubernetes 1.25+; GKE enforces Pod Security Admission instead.
#tfsec:ignore:google-gke-enable-master-networks Endpoint intentionally open for GitHub-hosted runners (dynamic IPs); lock down via var.master_authorized_cidrs. IAM auth is still required.
#tfsec:ignore:google-gke-enable-network-policy NetworkPolicy is enforced by Dataplane V2 (datapath_provider = ADVANCED_DATAPATH).
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone

  resource_labels             = local.labels
  enable_intranode_visibility = true

  #checkov:skip=CKV_GCP_12:NetworkPolicy is enforced by Dataplane V2 (ADVANCED_DATAPATH); the legacy network_policy addon is mutually exclusive with it.
  #checkov:skip=CKV_GCP_69:GKE Metadata Server (GKE_METADATA) is enabled on every node pool; Checkov only inspects inline cluster node_config, which we don't use.
  #checkov:skip=CKV_GCP_66:Binary Authorization is out of scope for this project.
  #checkov:skip=CKV_GCP_65:Google Groups for RBAC requires a Workspace domain, not available on a personal GCP project.

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  # Manage node pools separately (below).
  remove_default_node_pool = true
  initial_node_count       = 1

  # Allow `terraform destroy` to delete the cluster.
  deletion_protection = false

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.subnet.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.subnet.secondary_ip_range[1].range_name
  }

  # --- Security hardening ---------------------------------------------------

  # Shielded GKE nodes (secure boot / integrity monitoring at cluster level).
  enable_shielded_nodes = true

  # Nodes get no public IPs; egress goes through Cloud NAT (below).
  # Control-plane endpoint stays public so CI/kubectl can reach it.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Optionally restrict who can reach the control-plane endpoint.
  # Leave empty to allow all (needed for GitHub-hosted runners with dynamic IPs).
  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_cidrs) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_cidrs
        content {
          cidr_block = cidr_blocks.value
        }
      }
    }
  }

  # Dataplane V2 (Cilium) — provides Kubernetes NetworkPolicy enforcement.
  datapath_provider = "ADVANCED_DATAPATH"

  # No client certificate / basic auth.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # GCS Fuse CSI driver so vLLM can mount the model bucket as a local path.
  addons_config {
    gcs_fuse_csi_driver_config {
      enabled = true
    }
  }

  depends_on = [google_project_service.services]
}

# ---------------------------------------------------------------------------
# App node pool — always-on, runs the Streamlit app / pipeline (cheap)
# ---------------------------------------------------------------------------
#tfsec:ignore:google-gke-metadata-endpoints-disabled Legacy endpoints are disabled via metadata + GKE_METADATA (Workload Identity) mode; tfsec does not read metadata on standalone node_pool resources.
resource "google_container_node_pool" "app" {
  name     = "app-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name

  initial_node_count = 1
  autoscaling {
    min_node_count = 1
    max_node_count = 2
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.app_machine_type
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = local.labels

    metadata = {
      "disable-legacy-endpoints" = "true"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

# ---------------------------------------------------------------------------
# Serve node pool — runs vLLM on CPU. Scales to 0 when idle to save cost.
# Tainted so only vLLM (with the matching toleration) lands here, which lets
# the node scale back to 0 cleanly when vLLM is scaled down.
# ---------------------------------------------------------------------------
#tfsec:ignore:google-gke-metadata-endpoints-disabled Legacy endpoints are disabled via metadata + GKE_METADATA (Workload Identity) mode; tfsec does not read metadata on standalone node_pool resources.
resource "google_container_node_pool" "serve" {
  name     = "serve-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name

  initial_node_count = 0
  autoscaling {
    min_node_count = 0
    max_node_count = 1
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.serve_machine_type
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    metadata = {
      "disable-legacy-endpoints" = "true"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = merge(local.labels, {
      workload = "vllm"
    })

    taint {
      key    = "dedicated"
      value  = "vllm"
      effect = "NO_SCHEDULE"
    }
  }
}

# ---------------------------------------------------------------------------
# Artifact Registry — Docker repo for the app image
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository" "repo" {
  #checkov:skip=CKV_GCP_84:Google-managed encryption is acceptable; CMEK/CSEK omitted to keep free-tier cost/complexity down.
  location      = var.region
  repository_id = var.artifact_repo_name
  format        = "DOCKER"
  description   = "Anime recommender app images"

  depends_on = [google_project_service.services]
}

# ---------------------------------------------------------------------------
# GCS bucket for model weights (vLLM pulls the model from here)
# ---------------------------------------------------------------------------
#tfsec:ignore:google-storage-bucket-encryption-customer-key Google-managed encryption at rest is acceptable for this project (no CMEK/KMS to keep free-tier cost/complexity down).
resource "google_storage_bucket" "models" {
  #checkov:skip=CKV_GCP_62:Access logging omitted (would require a second log bucket); not needed for this project.
  name     = local.model_bucket_name
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true # wipe objects on `terraform destroy`

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.services]
}

# ---------------------------------------------------------------------------
# Workload-identity SA the vLLM/app pods use to read the model bucket
# ---------------------------------------------------------------------------
resource "google_service_account" "app" {
  account_id   = "${var.cluster_name}-app"
  display_name = "vLLM / app workload identity SA"
}

resource "google_storage_bucket_iam_member" "app_model_reader" {
  bucket = google_storage_bucket.models.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.app.email}"
}

# Bind the Google SA to the Kubernetes SA (<namespace>/<ksa>) via Workload Identity.
resource "google_service_account_iam_member" "app_wi" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.k8s_service_account}]"
}
