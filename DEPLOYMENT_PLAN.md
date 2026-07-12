# Self-Hosted vLLM + llm-d on GCP, with an LLMSecOps Layer

## Context

The repo is currently a small LangChain RAG app (`app/app.py` → `pipeline/pipeline.py` → `src/recommender.py`) that calls **Groq's hosted API** (`ChatGroq`, `llama-3.1-8b-instant`) for generation, with a locally-persisted Chroma vector store for retrieval. Deployment is a single Streamlit container behind one bare `k8s.yaml` Deployment/Service — no GPU serving, no security tooling, no observability.

Goal: turn this into a hands-on learning project + portfolio piece that demonstrates (1) self-hosting an LLM with **vLLM + llm-d** on **GKE**, weights served from a **GCS bucket**, and (2) a real **LLMSecOps** layer on top — the part you want the most depth on. Hard constraint: **only the $300 GCP free-trial credit**. You are driving this yourself for the learning experience — this doc is the map; come back phase by phase and I'll help write the actual commands/manifests/code and explain what's happening as we go.

Two pre-existing bugs surface naturally during this refactor, fixed in passing:
- `config/config.py` defines `GROQ_API_URL`/`MODEL_NAME` but not `GROQ_API_KEY`, yet `pipeline/pipeline.py:3` imports `GROQ_API_KEY` — this import currently fails.
- `utils/logger.py` logs to a local file. GKE/Cloud Logging only ingests container stdout/stderr, so this must become stdout logging for the observability pillar to work.

---

## vLLM vs. llm-d — what each one actually buys you

**vLLM = the inference engine.** Runs the model on a GPU and answers requests efficiently:
- **PagedAttention** manages the KV-cache (per-token attention memory) like an OS pages virtual memory, instead of one big contiguous allocation per request — eliminates memory fragmentation, fits far more concurrent requests in the same VRAM.
- **Continuous batching** adds/removes sequences from the running batch every decode step, so the GPU is never idle waiting on the slowest request in a fixed batch.
- **OpenAI-compatible HTTP API** (`/v1/chat/completions`) — why `langchain_openai.ChatOpenAI` can talk to it as a drop-in replacement for Groq.
- Quantization (AWQ/GPTQ/FP8) and prefix caching to fit bigger models / reuse repeated context cheaply.

vLLM answers: *"how do I serve one model on one set of GPUs as fast and memory-efficiently as possible?"* — a single server process (or a handful of replicas).

**llm-d = the fleet/orchestration layer, built on top of vLLM, on Kubernetes.** Once you have more than one vLLM replica, how do you route each request to the *right* one?
- Built on the **Gateway API Inference Extension** (Kubernetes SIG standard): `InferencePool` (a pool of model pods) + `InferenceModel` (the served model + priority).
- A **smart scheduler ("EPP")** picks the pod per-request using real signals — KV-cache occupancy, queue depth, and **prefix-cache affinity** (route requests sharing a prompt prefix back to the pod that already has it cached) — instead of the dumb round-robin a plain `Service` does.
- **Prefill/decode disaggregation** (llm-d's flagship feature): splits compute-heavy prompt-processing from memory-bandwidth-heavy token-generation across different pods/GPUs. Needs multiple GPUs → **explicitly out of scope** for our single-L4 budget build. Worth knowing about, not worth paying for here.
- A standard Gateway as the front door, plus inference-aware autoscaling.

**Analogy:** vLLM is a highly optimized single database engine. llm-d is the connection pooler + smart router in front of a fleet of replicas that knows which one has your data cached.

**Why install llm-d for a single-GPU demo, if there's only one pod to route to?** You learn the real control-plane objects (`InferencePool`, `InferenceModel`, `Gateway`, `HTTPRoute`) — identical manifests to what you'd run with 5 replicas, just `min=1`. It's also the current industry-standard pattern (Google/Red Hat/CoreWeave-backed), so having it wired up reads very differently than a bare `Service` on a portfolio. And the Gateway becomes the natural front door for the LLMSecOps guardrails layer later.

---

## Guiding principles

1. **Budget first.** Everything touching the GPU node pool defaults to scale-to-zero, spot VMs, explicit start/stop scripts.
2. **llm-d is deliberately scoped down.** Single vLLM replica behind one `InferencePool`/Gateway — no disaggregation, no multi-replica autoscaling. Documented as an intentional tradeoff, good portfolio narrative.
3. **LLMSecOps gets the depth.** Phases 1–2 (serving) are the thinnest slice of new engineering; Phases 3–6 (the four security pillars) get the most new code and time.
4. **Guardrails sit in front of the model, not inside `src/`.**

---

## Budget reality check ($300 free-trial credit)

Estimates for `us-central1` — verify exact current pricing at deploy time:

| Resource | Rate | Notes |
|---|---|---|
| `g2-standard-4` + 1x L4, **spot** | ~$0.20–0.30/hr | Only runs while `gpu-pool` is scaled to 1 |
| `g2-standard-4` + 1x L4, on-demand | ~$0.70/hr | Fallback if spot gets preempted a lot |
| `e2-small` (app node) | ~$0.02/hr | Fine to leave running 24/7 |
| GKE Standard control plane | $0 | One zonal cluster per billing account is free |
| GCS storage (~16GB weights) | <$1/month | One-time upload |
| Cloud Trace/Logging/Managed Prometheus | Free tier covers this scale | |

**Realistic total spend:** 40–60 GPU-hours across dev + demo (generous) ≈ **$10–20** of your $300. The real risk isn't the workload — it's **forgetting to scale the GPU pool to 0**; a week left running by accident is $35–120. `gpu-pool-stop.sh` + a billing alert are set up in Phase 0/1, before any GPU node exists.

**Fallback if L4 quota is denied/slow:** request `NVIDIA_T4_GPUS` instead — cheaper, more often auto-approved, but 16GB VRAM is tight for Llama-3.1-8B fp16. If you land on T4, serve an **AWQ/GPTQ 4-bit** build instead — vLLM supports this natively and it's a legitimate skill to show.

---

## Phase 0 — GCP Account & Quota Prep (do this first — the one real wall-clock wait)

Free-trial billing accounts are **hard-blocked from GPUs and GPU quota increases.** All user actions:

1. Cloud Console → Billing → **Upgrade** the free-trial account to a paid account. This keeps the $300 credit, doesn't forfeit it.
2. Set a budget alert right after upgrading:
   ```bash
   gcloud billing budgets create \
     --billing-account=YOUR_BILLING_ACCOUNT_ID \
     --display-name="anime-rec-budget" \
     --budget-amount=250 \
     --threshold-rule=percent=50 \
     --threshold-rule=percent=80 \
     --threshold-rule=percent=100
   ```
3. IAM & Admin → Quotas → filter `NVIDIA L4 GPUs`, region `us-central1`, request increase to 1–2. Not scriptable. Approval: minutes to ~1 week — **request this immediately, it's the biggest scheduling risk in the whole project.**
4. Give me: project ID, billing account ID, region/zone, confirmation once quota clears.

While quota is pending we can do everything below that doesn't need a live GPU node (cluster creation, bucket setup, manifests, guardrails code).

---

## Phase 1 — Minimal Self-Hosted Baseline (vLLM + GCS + GKE, swap off Groq)

Prove the plumbing works before llm-d or security gets layered on.

### 1.1 Enable APIs
```bash
gcloud services enable container.googleapis.com storage.googleapis.com \
  compute.googleapis.com iam.googleapis.com --project=YOUR_PROJECT_ID
```

### 1.2 Create the GKE cluster (zonal Standard — free control plane, full node-pool control)
```bash
gcloud container clusters create anime-rec-cluster \
  --zone=us-central1-a \
  --machine-type=e2-small \
  --num-nodes=1 \
  --workload-pool=YOUR_PROJECT_ID.svc.id.goog
```

### 1.3 Add the GPU node pool — spot, scales to zero
```bash
gcloud container node-pools create gpu-pool \
  --cluster=anime-rec-cluster --zone=us-central1-a \
  --machine-type=g2-standard-4 \
  --accelerator=type=nvidia-l4,count=1,gpu-driver-version=latest \
  --spot \
  --enable-autoscaling --min-nodes=0 --max-nodes=1 \
  --num-nodes=0
```

### 1.4 Enable the Cloud Storage FUSE CSI driver (mounts the GCS bucket into pods)
```bash
gcloud container clusters update anime-rec-cluster --zone=us-central1-a \
  --update-addons=GcsFuseCsiDriver=ENABLED
```

### 1.5 Create the model bucket + Workload Identity so the pod can read it without embedded keys
```bash
gsutil mb -l us-central1 gs://YOUR_PROJECT_ID-anime-rec-models

gcloud iam service-accounts create vllm-gcs-reader

gsutil iam ch \
  serviceAccount:vllm-gcs-reader@YOUR_PROJECT_ID.iam.gserviceaccount.com:roles/storage.objectViewer \
  gs://YOUR_PROJECT_ID-anime-rec-models

gcloud iam service-accounts add-iam-policy-binding \
  vllm-gcs-reader@YOUR_PROJECT_ID.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:YOUR_PROJECT_ID.svc.id.goog[default/vllm-sa]"
```
Then create a Kubernetes `ServiceAccount` named `vllm-sa` annotated with `iam.gke.io/gcp-service-account: vllm-gcs-reader@YOUR_PROJECT_ID.iam.gserviceaccount.com`.

### 1.6 Download the model once, upload only safetensors (Cloud Shell)
Accept the Meta Llama-3.1 license on Hugging Face first, then:
```bash
pip install -U "huggingface_hub[cli]"
huggingface-cli login   # short-lived token, one-time use, not stored in repo
huggingface-cli download meta-llama/Llama-3.1-8B-Instruct \
  --local-dir ./llama-3.1-8b-instruct --exclude "*.pth" "original/*"
gsutil -m cp -r ./llama-3.1-8b-instruct gs://YOUR_PROJECT_ID-anime-rec-models/
```
Only `.safetensors` land in the bucket — never pickle/`.bin`. This closes off unsafe-deserialization risk from day one and sets up Phase 4's supply-chain check.

### 1.7 Deploy vLLM (`k8s/vllm-deployment.yaml` + `k8s/vllm-service.yaml`)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
spec:
  replicas: 1
  selector: {matchLabels: {app: vllm}}
  template:
    metadata:
      labels: {app: vllm}
      annotations: {gke-gcsfuse/volumes: "true"}
    spec:
      serviceAccountName: vllm-sa
      nodeSelector: {cloud.google.com/gke-accelerator: nvidia-l4}
      tolerations:
        - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
      containers:
        - name: vllm
          image: vllm/vllm-openai@sha256:<pin-this-digest-at-build-time>
          args:
            - --model=/mnt/models/llama-3.1-8b-instruct
            - --served-model-name=llama-3.1-8b-instruct
            - --max-model-len=8192
            - --gpu-memory-utilization=0.90
          resources: {limits: {nvidia.com/gpu: 1}}
          ports: [{containerPort: 8000}]
          volumeMounts:
            - {name: model-bucket, mountPath: /mnt/models, readOnly: true}
      volumes:
        - name: model-bucket
          csi:
            driver: gcsfuse.csi.storage.gke.io
            volumeAttributes:
              bucketName: YOUR_PROJECT_ID-anime-rec-models
              mountOptions: "implicit-dirs,file-cache:max-size-mb:-1"
---
apiVersion: v1
kind: Service
metadata: {name: vllm}
spec:
  selector: {app: vllm}
  ports: [{port: 8000, targetPort: 8000}]   # ClusterIP only — never public
```
Test: `kubectl port-forward svc/vllm 8000:8000`, then `curl localhost:8000/v1/chat/completions -d '{...}'`.

### 1.8 App changes
- `src/recommender.py`: swap `ChatGroq` → `langchain_openai.ChatOpenAI` against an OpenAI-compatible `base_url`.
- New `src/llm_provider.py`: factory returning Groq (free, fast local UI iteration) or vLLM-backed client via an `LLM_PROVIDER` env var — deliberate cost control so you're not spinning the GPU pool for every UI tweak.
- `config/config.py`: add `LLM_PROVIDER`, `VLLM_BASE_URL`, `GCP_PROJECT`, `GCS_BUCKET`; fix the missing `GROQ_API_KEY`.
- `pipeline/pipeline.py`: thread through new config, no structural change.
- `requirements.txt`: add `langchain-openai`; keep `langchain_groq` as the dev-loop option.
- `utils/logger.py`: file logging → stdout `StreamHandler` (full JSON structuring comes in Phase 5).
- `k8s.yaml` retired → replaced by a `k8s/` directory (`app-deployment.yaml`, `app-service.yaml` carry its old content, plus the vLLM manifests above).

### 1.9 Embeddings go local and framework-free
`src/vector_store.py` currently wraps `sentence-transformers` inside `langchain_huggingface.HuggingFaceEmbeddings`, then wraps *that* inside `langchain_community.vectorstores.Chroma` — two layers of LangChain hiding what's happening, which fights the "control every step" LLMSecOps narrative. Replace with:
- A small class calling `sentence_transformers.SentenceTransformer("all-MiniLM-L6-v2")` directly (`.encode()`), implementing Chroma's plain `EmbeddingFunction` protocol.
- Raw `chromadb.PersistentClient` + `collection.add()`/`collection.query()` instead of `langchain_community.vectorstores.Chroma`.
- Gives Phase 3's guardrails a clean choke point to sanitize text *before* it's embedded.
- `requirements.txt`: drop `langchain_huggingface` and LangChain's Chroma integration; keep `chromadb` and `sentence-transformers` directly.

**Milestone:** in-cluster Streamlit → in-cluster vLLM produces a real recommendation, zero Groq calls. Immediately run `gpu-pool-stop.sh`.

---

## Phase 2 — Install llm-d's Inference Gateway on the Same vLLM Backend

> llm-d's exact Helm chart names/repo URLs move fast (project is under 1 year old) — verify against `llm-d.ai/docs` at execution time rather than trusting these verbatim; I'll re-check when we get here.

### 2.1 Install the Gateway API + Inference Extension CRDs
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/manifests.yaml
```

### 2.2 Install llm-d's inference-scheduling "well-lit path" via Helm
```bash
helm repo add llm-d https://llm-d.ai/charts
helm install llm-d-scheduler llm-d/llm-d-inference-scheduler -n llm-d --create-namespace
```

### 2.3 Declare the pool + model (`k8s/llm-d/`)
```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferencePool
metadata: {name: vllm-pool}
spec:
  targetPortNumber: 8000
  selector: {app: vllm}          # selects Phase 1's existing pods, no pod-spec change
  extensionRef: {name: llm-d-scheduler}
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata: {name: llama-3-1-8b}
spec:
  modelName: llama-3.1-8b-instruct
  poolRef: {name: vllm-pool}
  criticality: Critical
```

### 2.4 Gateway + route, using GKE's managed Gateway controller (no separate Envoy install to babysit)
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: inference-gateway}
spec:
  gatewayClassName: gke-l7-rilb   # internal load balancer, no public IP
  listeners: [{name: http, port: 80, protocol: HTTP}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: vllm-route}
spec:
  parentRefs: [{name: inference-gateway}]
  rules:
    - backendRefs:
        - {group: inference.networking.x-k8s.io, kind: InferencePool, name: vllm-pool}
```

### 2.5 Repoint the app
`VLLM_BASE_URL` now points at the Gateway (still internal-only) instead of the raw vLLM `Service`.

**Verify:** same query flow as Phase 1, but confirm via `kubectl get httproute`/Gateway status and vLLM logs that traffic is actually flowing through the `InferencePool`, not a direct Service call. This is the milestone — you've now got the real llm-d control plane running, even with one replica.

README should state the scope-down rationale explicitly (no disaggregation/multi-replica — budget) so it reads as an informed decision, not a gap. The Gateway is now the natural chokepoint for Phase 3.

---

## Design decision: where do guardrails live?

**A standalone proxy in new `security/guardrails-proxy/`, sitting between the app and the llm-d Gateway — not inline in `src/`.**

Centralizes enforcement so a bug in `src/` can't silently bypass it, matches production practice (AI-gateway pattern — LiteLLM proxy / Envoy `ext_proc` / NeMo Guardrails as a service), and reads as credible engineering vs. a few `if` checks in `recommender.py`. An Envoy `ext_proc` filter on the Gateway itself was considered and rejected — deeper plumbing for marginal benefit; noted as future work. `VLLM_BASE_URL` gets repointed once more, at the proxy — the only pipeline-code touch the entire LLMSecOps layer needs.

---

## Phase 3 — Prompt Injection / Jailbreak Guardrails

- **Classifier:** Meta's **Llama Prompt Guard 2** (86M params, CPU-only, no second GPU) scores incoming queries for injection/jailbreak likelihood.
- **Rules/topicality:** **NeMo Guardrails** (Colang) for domain-specific rejections (system-prompt extraction attempts, off-topic abuse) — cheap CPU logic.
- **Output-side check:** lighter pass on the model's response before returning it (system-prompt leakage, refusal-bypass patterns).
- New: `security/guardrails-proxy/{app.py,classifiers/prompt_guard.py,rails/,Dockerfile}`, `k8s/guardrails-proxy-deployment.yaml` (non-GPU node pool).

## Phase 4 — Model & Artifact Supply-Chain Security

- **Weight integrity:** hash every `.safetensors` shard at upload time into a manifest (GCS + pinned in-repo); an **initContainer** on the vLLM pod re-hashes the GCS-FUSE-mounted files against it, fails fast on mismatch.
- **Format enforcement:** CI check that only `.safetensors` ever lands in the bucket.
- **Provenance:** sign images + the model manifest with **cosign**; pin every image reference by digest.
- **SBOM + CVE gate:** **Syft** for SBOMs, **Grype** to scan, CI fails on high/critical.
- New: `security/supply-chain/{generate_manifest.py,verify_manifest.py,model-manifest.json}`, `.github/workflows/supply-chain.yml`.

## Phase 5 — Observability & Abuse Monitoring

- `utils/logger.py` → structured JSON on stdout; GKE ships it to **Cloud Logging** automatically. Logs: timestamp, query hash (not raw text), guardrail verdict, latency, token counts, model version.
- **OpenTelemetry** in the proxy + pipeline, OTLP → **Cloud Trace**; vLLM's native `--otlp-traces-endpoint` wired into the same trace.
- vLLM's `/metrics` scraped by **Cloud Managed Service for Prometheus**. Dashboard (`infra/monitoring/dashboard.json`) showing request rate, **guardrail-block rate**, throughput, GPU utilization, p50/p95 latency.
- Alert policy on guardrail-block-rate spikes.
- New: `security/observability/otel_setup.py`, `infra/monitoring/{dashboard.json,alert-policy.yaml}`.

## Phase 6 — Red-Teaming / Adversarial Eval CI Gate

- **PR-time (cheap, every PR):** **promptfoo** with a domain-specific adversarial suite against the guardrails-proxy logic — no GPU needed.
- **Nightly (heavier):** **garak** against the live vLLM endpoint, scoped probe subset (`promptinject`, `dan`, `encoding`, `leakreplay`): scale GPU pool up → wait for readiness → run garak → fail on threshold breach → **scale back to zero in a `finally` block**, backed by a Cloud Scheduler force-scale-to-0 safety net after a hard 2-hour ceiling.
- New: `security/redteam/{promptfoo-config.yaml,garak-config.yaml}`, `.github/workflows/{redteam-pr.yml,redteam-nightly.yml}`, `scripts/gpu-pool-scale.sh`.

---

## Consolidated file-level change inventory

**Existing files that change:** `src/recommender.py`, `config/config.py`, `pipeline/pipeline.py`, `utils/logger.py`, `requirements.txt`, `dockerfile`, `k8s.yaml` (deleted → `k8s/` directory). `pipeline/build_pipeline.py` stays functionally as-is.

**New:** `k8s/` (app/vllm/guardrails-proxy manifests + `k8s/llm-d/`), `src/llm_provider.py`, `security/guardrails-proxy/`, `security/supply-chain/`, `security/observability/otel_setup.py`, `security/redteam/`, `infra/monitoring/`, `scripts/` (start/stop/scale/upload), `.github/workflows/` (supply-chain, redteam-pr, redteam-nightly).

---

## Session count & pause points

Roughly **12–16 sessions**, weighted toward the security pillars, plus one real wall-clock wait:

| Phase | Sessions | Blocks on user? |
|---|---|---|
| 0 — GCP prep | 1 (+ wait) | Yes — billing upgrade, quota approval (minutes–1 wk) |
| 1 — vLLM+GCS+GKE baseline | 2–3 | Partial — HF token, project/region |
| 2 — llm-d gateway | 1–2 | No |
| 3 — Guardrails proxy | 2 | No |
| 4 — Supply chain | 1–2 | Partial — CI-to-GCP auth (Workload Identity Federation) |
| 5 — Observability | 1–2 | No |
| 6 — Red-team CI | 2 | Partial — approval for cost-incurring nightly job |
| Cost governance / docs polish | 1 | No |

**Explicit pause-for-user-action points:** billing upgrade; quota request + wait; project/region/billing-account handoff; HF license acceptance + token; review/approve each cost-affecting infra change; GitHub Actions↔GCP auth setup; go-ahead before nightly garak runs; periodic manual check the GPU pool isn't left running (mitigated by budget alerts + the Cloud Scheduler safety net).

---

## Verification (end-to-end, per phase)

- **Phase 1:** `kubectl port-forward` the app service locally, submit a real query in the Streamlit UI, confirm a recommendation returns and `kubectl logs` on the vLLM pod shows the request — no Groq traffic. Run `gpu-pool-stop.sh` immediately after.
- **Phase 2:** same query flow, but confirm via `kubectl get httproute`/Gateway status and vLLM logs that traffic is routed through the `InferencePool`, not the raw Service directly.
- **Phase 3:** send a known jailbreak/prompt-injection string through the app and confirm the proxy blocks it and logs a verdict; confirm a benign query still passes through unaffected.
- **Phase 4:** intentionally corrupt one byte of a GCS-hosted shard and confirm the vLLM pod's initContainer fails startup instead of serving corrupted weights; confirm CI fails a build if a non-`.safetensors` file is added to the bucket path.
- **Phase 5:** confirm the Cloud Monitoring dashboard renders live GPU utilization + guardrail-block-rate during a test query burst, and that a trace for one request shows spans across proxy → retrieval → generation in Cloud Trace.
- **Phase 6:** intentionally submit a bad PR (obvious guardrail gap) and confirm the promptfoo CI check fails; manually trigger the nightly garak workflow once and confirm it scales the GPU pool down afterward regardless of pass/fail.
