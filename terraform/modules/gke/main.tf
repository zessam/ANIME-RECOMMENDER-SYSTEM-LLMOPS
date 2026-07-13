# ---------------------------------------------------------------------------
# Service account used by the GKE nodes (least privilege)
# ---------------------------------------------------------------------------
resource "google_service_account" "nodes" {
  account_id   = "${var.name}-nodes"
  display_name = "GKE node service account for ${var.name}"
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
# GKE cluster (zonal, VPC-native, Workload Identity, private nodes)
# ---------------------------------------------------------------------------
#tfsec:ignore:google-gke-enforce-pod-security-policy PSP was removed in Kubernetes 1.25+; GKE enforces Pod Security Admission instead.
#tfsec:ignore:google-gke-enable-master-networks Endpoint intentionally open for GitHub-hosted runners (dynamic IPs); lock down via var.master_authorized_cidrs. IAM auth is still required.
#tfsec:ignore:google-gke-enable-network-policy NetworkPolicy is enforced by Dataplane V2 (datapath_provider = ADVANCED_DATAPATH).
resource "google_container_cluster" "primary" {
  name     = var.name
  location = var.zone

  resource_labels             = var.labels
  enable_intranode_visibility = true

  #checkov:skip=CKV_GCP_12:NetworkPolicy is enforced by Dataplane V2 (ADVANCED_DATAPATH); the legacy network_policy addon is mutually exclusive with it.
  #checkov:skip=CKV_GCP_69:GKE Metadata Server (GKE_METADATA) is enabled on every node pool; Checkov only inspects inline cluster node_config, which we don't use.
  #checkov:skip=CKV_GCP_66:Binary Authorization is out of scope for this project.
  #checkov:skip=CKV_GCP_65:Google Groups for RBAC requires a Workspace domain, not available on a personal GCP project.

  network    = var.network_id
  subnetwork = var.subnet_id

  # Manage node pools separately (below).
  remove_default_node_pool = true
  initial_node_count       = 1

  # Allow `terraform destroy` to delete the cluster.
  deletion_protection = false

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # --- Security hardening ---------------------------------------------------

  # Shielded GKE nodes (secure boot / integrity monitoring at cluster level).
  enable_shielded_nodes = true

  # Nodes get no public IPs; egress goes through Cloud NAT.
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
}

# ---------------------------------------------------------------------------
# App node pool — always-on, runs the Streamlit app / pipeline (cheap)
# ---------------------------------------------------------------------------
#tfsec:ignore:google-gke-metadata-endpoints-disabled Legacy endpoints are disabled via metadata + GKE_METADATA (Workload Identity) mode; tfsec does not read metadata on standalone node_pool resources.
resource "google_container_node_pool" "app" {
  name     = "app-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name

  # Autoscale so the scheduler can add a second node when pods don't fit
  # (e.g. app + monitoring). Stays at 1 node when everything fits, so cost only
  # grows on demand. Peak (2 app + 1 serve) = 8 vCPU = default free-tier quota.
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
    disk_size_gb    = var.disk_size_gb
    disk_type       = var.disk_type
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = var.labels

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
    disk_size_gb    = var.disk_size_gb
    disk_type       = var.disk_type
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

    labels = merge(var.labels, {
      workload = "vllm"
    })

    taint {
      key    = "dedicated"
      value  = "vllm"
      effect = "NO_SCHEDULE"
    }
  }
}
