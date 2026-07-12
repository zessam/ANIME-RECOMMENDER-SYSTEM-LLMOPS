package main

import rego.v1

# Policy-as-code for the model bucket. Evaluated by conftest against the
# Terraform plan JSON (`terraform show -json tfplan`).

# Buckets must block all public access.
deny contains msg if {
	some resource in input.resource_changes
	resource.type == "google_storage_bucket"
	resource.change.after.public_access_prevention != "enforced"
	msg := sprintf("%s: bucket must set public_access_prevention = \"enforced\"", [resource.address])
}

# Buckets must use uniform bucket-level access (no legacy ACLs).
deny contains msg if {
	some resource in input.resource_changes
	resource.type == "google_storage_bucket"
	resource.change.after.uniform_bucket_level_access != true
	msg := sprintf("%s: bucket must enable uniform_bucket_level_access", [resource.address])
}
