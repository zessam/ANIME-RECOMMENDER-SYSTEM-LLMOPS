package main

import rego.v1

# Policy-as-code for the GKE cluster and node pools. Evaluated by conftest
# against the Terraform plan JSON (`terraform show -json tfplan`).

# Node pools must use a dedicated (non-default) service account.
deny contains msg if {
	some resource in input.resource_changes
	resource.type == "google_container_node_pool"
	some nc in resource.change.after.node_config
	not nc.service_account
	msg := sprintf("%s: node pool must set a dedicated service_account", [resource.address])
}

deny contains msg if {
	some resource in input.resource_changes
	resource.type == "google_container_node_pool"
	some nc in resource.change.after.node_config
	nc.service_account == "default"
	msg := sprintf("%s: node pool must not use the default compute service account", [resource.address])
}

# Node pools must enable Shielded VM secure boot.
deny contains msg if {
	some resource in input.resource_changes
	resource.type == "google_container_node_pool"
	some nc in resource.change.after.node_config
	not secure_boot_enabled(nc)
	msg := sprintf("%s: node pool must enable shielded secure boot", [resource.address])
}

secure_boot_enabled(nc) if {
	some sic in nc.shielded_instance_config
	sic.enable_secure_boot == true
}

# Node pools must run the GKE metadata server (Workload Identity).
deny contains msg if {
	some resource in input.resource_changes
	resource.type == "google_container_node_pool"
	some nc in resource.change.after.node_config
	not gke_metadata(nc)
	msg := sprintf("%s: node pool must set workload_metadata_config mode = GKE_METADATA", [resource.address])
}

gke_metadata(nc) if {
	some wmc in nc.workload_metadata_config
	wmc.mode == "GKE_METADATA"
}

# Cluster must enable Workload Identity.
deny contains msg if {
	some resource in input.resource_changes
	resource.type == "google_container_cluster"
	count(object.get(resource.change.after, "workload_identity_config", [])) == 0
	msg := sprintf("%s: cluster must enable Workload Identity", [resource.address])
}

# Cluster must enable Shielded Nodes.
deny contains msg if {
	some resource in input.resource_changes
	resource.type == "google_container_cluster"
	resource.change.after.enable_shielded_nodes != true
	msg := sprintf("%s: cluster must set enable_shielded_nodes = true", [resource.address])
}

# Cluster must use private nodes.
deny contains msg if {
	some resource in input.resource_changes
	resource.type == "google_container_cluster"
	not private_nodes(resource.change.after)
	msg := sprintf("%s: cluster must set private_cluster_config.enable_private_nodes = true", [resource.address])
}

private_nodes(after) if {
	some pcc in after.private_cluster_config
	pcc.enable_private_nodes == true
}
