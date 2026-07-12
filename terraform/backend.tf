# Remote state in GCS so both the apply and destroy workflows share the same state.
# The bucket is NOT created by this Terraform (chicken-and-egg) — create it once
# during bootstrap (see terraform/README.md) and pass its name at init time:
#
#   terraform init -backend-config="bucket=<YOUR_STATE_BUCKET>"
#
terraform {
  backend "gcs" {
    prefix = "anime-rec/state"
  }
}
