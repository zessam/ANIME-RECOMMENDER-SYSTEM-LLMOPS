# Infrastructure (Terraform)

Provisions everything needed to run the Anime Recommender + vLLM on GKE.
**CPU-only** setup (no GPU) — fits the $300 free tier and needs no billing
upgrade or GPU quota. vLLM serves a small model (Qwen2.5-3B) on CPU.

- GKE cluster (zonal, VPC-native, Workload Identity)
- app-pool (`e2-standard-2`, autoscale 1→2) + serve-pool (vLLM on CPU, `e2-highmem-4` / 32GB, scales 0→1)
- Artifact Registry Docker repo (app image)
- GCS bucket for model weights (optional — vLLM can also pull from HF Hub directly)
- Workload-identity service account so pods can read the bucket

State lives in a **remote GCS bucket** so the apply and destroy GitHub Actions
share it.

---

## One-time bootstrap

You need these **before** the workflows can run.

### 1. Create the Terraform state bucket

```bash
PROJECT_ID=my-gcp-project-id
gsutil mb -p "$PROJECT_ID" -l us-central1 "gs://${PROJECT_ID}-tfstate"
gsutil versioning set on "gs://${PROJECT_ID}-tfstate"
```

### 2. Create the CI service account (no keys)

```bash
gcloud iam service-accounts create terraform-ci \
  --project "$PROJECT_ID" --display-name "Terraform CI"

SA="terraform-ci@${PROJECT_ID}.iam.gserviceaccount.com"

for ROLE in \
  roles/container.admin \
  roles/compute.admin \
  roles/artifactregistry.admin \
  roles/storage.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/resourcemanager.projectIamAdmin \
  roles/serviceusage.serviceUsageAdmin ; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:${SA}" --role "$ROLE"
done
```

### 3. Set up Workload Identity Federation (keyless auth)

No JSON key is created or stored. GitHub Actions authenticates via OIDC and
impersonates the SA above.

```bash
REPO="OWNER/REPO"   # <-- your GitHub repo, e.g. Zeyad/anime-recommender
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
POOL=github-pool
PROVIDER=github-provider

# 3a. Workload identity pool
gcloud iam workload-identity-pools create "$POOL" \
  --project="$PROJECT_ID" --location=global \
  --display-name="GitHub Actions pool"

# 3b. OIDC provider, restricted to your repo
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
  --project="$PROJECT_ID" --location=global \
  --workload-identity-pool="$POOL" \
  --display-name="GitHub provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${REPO}'"

# 3c. Let that repo impersonate the CI service account
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project="$PROJECT_ID" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"

# 3d. Print the two values you need for GitHub:
echo "SERVICE_ACCOUNT  = ${SA}"
echo -n "WORKLOAD_PROVIDER = "
gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --project="$PROJECT_ID" --location=global \
  --workload-identity-pool="$POOL" --format='value(name)'
```

### 4. Set GitHub secrets and variables

**Repo → Settings → Secrets and variables → Actions**

All under the **`production` environment** (Settings → Environments → production):

| Name | Kind | How to get it |
|------|------|---------------|
| `WORKLOAD_PROVIDER` | environment secret | output of step **3d** (`projects/<num>/locations/global/workloadIdentityPools/github-pool/providers/github-provider`) |
| `SERVICE_ACCOUNT` | environment secret | the SA email, e.g. `terraform-ci@<project>.iam.gserviceaccount.com` |
| `GCP_PROJECT_ID` | environment secret | your project ID (`gcloud config get-value project`) |
| `TF_STATE_BUCKET` | environment variable | the state bucket from step 1, e.g. `<project>-tfstate` |

> Because these are **environment**-scoped, every job that authenticates
> (`plan`, `apply`) references `environment: production`. `security-scan` and
> `policy` need no secrets, so they carry no environment.

> No `GCP_SA_KEY` — WIF is keyless, so there is no long-lived credential to leak.

### 5. Approval gate (optional)

Repo → **Settings → Environments → `production` → Required reviewers** (add
yourself). Any job pinned to `production` then waits for a human to click
**Approve**. **Note:** because the secrets live in `production`, this gates
`plan` **and** `apply` (and `destroy`) — every push will pause at `plan` for
approval. If you want `plan` to run freely but still gate `apply`/`destroy`, see
the note below.

> **Plan-auto + apply-approval:** to get that combo you must let `plan` reach the
> secrets without the reviewer gate — either move the secrets to **repository**
> scope, or create a second environment (e.g. `plan`, no reviewers) holding the
> same secrets for the `plan` job while `production` (with reviewers) gates
> apply/destroy.

---

## DevSecOps pipeline (`infra-build`)

Four stages: parallel source gates → plan → OPA policy → gated apply.

**Stage 1 — parallel source gates (all must pass before plan):**

| Job | What runs | Blocks? |
|-----|-----------|---------|
| `validate` | `terraform fmt -check` + `validate` | yes |
| `tfsec` | tfsec IaC scan (SARIF → Security tab) | findings surfaced |
| `checkov` | Checkov IaC scan (SARIF → Security tab) | findings surfaced |
| `gitleaks` | secret scan | **yes** on a hit |

**Stage 2 — `plan`** — `needs: [validate, tfsec, checkov, gitleaks]`; authenticated `terraform plan`, uploads `tfplan` + `plan.json`.

**Stage 3 — `policy`** — **OPA/conftest against the plan JSON** (`needs: plan`). Runs on the resolved, version-stable plan schema — **hard-blocks** on violation.

**Stage 4 — `apply`** — queued after `policy`; **waits for approval** on `production` (skipped only on PRs).

- **Any push touching `terraform/`** runs the gates → `plan` → `policy` → `apply` (which **waits for your approval**).
- **Pull requests** run everything except `apply`.
- **`Infra Destroy`** is a separate manual workflow that also requires the `production` approval **and** typing `destroy`.
- IaC findings (tfsec/Checkov) appear under the repo's **Security → Code scanning** tab.

> ⚠️ **Required reviewers are mandatory.** `apply` no longer gates on
> `workflow_dispatch`, so the **only** thing stopping an automatic apply on push
> is the `production` environment's **Required reviewers**. If that isn't set,
> pushes will apply automatically. Set it: Settings → Environments → `production`
> → Required reviewers.

### Policy-as-code (OPA / conftest)

Rego policies live in [`policy/`](policy/) and run **after plan**, against the
`terraform show -json` output. The plan JSON is a stable, fully-resolved schema
(HCL parsing varies between conftest versions), so this is the robust place for
policy. They **hard-block** the pipeline on violation. Current rules:

- Buckets must enforce `public_access_prevention` and uniform bucket-level access.
- Node pools must use a dedicated SA, shielded secure boot, and `GKE_METADATA`.
- Cluster must enable Workload Identity, Shielded Nodes, and private nodes.

Run them locally against a plan:

```bash
cd terraform
terraform plan -out=tfplan && terraform show -json tfplan > plan.json
conftest test plan.json -p policy
```

The Terraform is hardened to pass tfsec + Checkov cleanly; the few non-applicable
checks are suppressed inline with a documented reason (`#tfsec:ignore:` /
`#checkov:skip=`).

## Running

- **Build infra:** Actions → *Infra Build* → Run workflow
- **Destroy infra:** Actions → *Infra Destroy* → Run workflow → type `destroy`

## Local runs (optional)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set project_id
terraform init -backend-config="bucket=${PROJECT_ID}-tfstate"
terraform plan
terraform apply
```

---

## After apply — connect and deploy

Terraform prints the useful values as outputs:

```bash
terraform output get_credentials_command   # configure kubectl
terraform output artifact_registry_url     # where to push the app image
terraform output model_bucket              # gs:// bucket for the model
terraform output ksa_annotation_command    # wire K8s SA -> Google SA
```

Typical next steps (not managed by this Terraform):

1. `gcloud auth configure-docker <region>-docker.pkg.dev`, then build/push the app image.
2. Upload the model to the bucket, e.g.
   `gcloud storage cp -r ./model gs://<bucket>/models/<name>`.
3. Create the `anime-sa` ServiceAccount in the cluster and annotate it with the
   `ksa_annotation_command` output.
4. Deploy vLLM on the serve pool. Its pod must set:
   - `nodeSelector: { workload: vllm }`
   - a toleration for `dedicated=vllm:NoSchedule`
   - image `vllm/vllm-openai-cpu`, serving `Qwen/Qwen2.5-3B-Instruct`
   - `resources.requests.memory: ~14Gi`, and env `VLLM_CPU_KVCACHE_SPACE=4`
   Then deploy the app pointing `VLLM_BASE_URL` at the vLLM service.

## Sizing (why these machines)

| Pool | Machine | Allocatable | Hosts |
|------|---------|-------------|-------|
| app | `e2-standard-2` (2 vCPU / 8GB), autoscale 1→2 | ~1930m CPU / 6.1GB | Streamlit app + pipeline (+ light monitoring) |
| serve | `e2-highmem-4` (4 vCPU / 32GB), scale 0→1 | ~3920m CPU / 28.3GB | vLLM serving Qwen2.5-3B (~13-15GB) |

Peak usage (app scaled to 2 + serve up) = **8 vCPU** = the default free-tier
regional quota. Steady state is 2–6 vCPU. `e2-medium` was too small (only
~940m allocatable CPU after GKE's flat 1060m reservation on shared-core E2).

## Cost discipline (free tier / $300 credit)

- The serve pool scales to 0 — **scale the vLLM Deployment to 0 replicas when
  not testing** so the `e2-highmem-4` node drains and billing stops.
- Always-on cost ≈ 1× `e2-standard-2` (~$0.067/hr) + Cloud NAT (~$0.044/hr).
- Run **Infra Destroy** (or `terraform destroy`) between work sessions — this is
  the biggest saver; state is remote so you can rebuild anytime.
