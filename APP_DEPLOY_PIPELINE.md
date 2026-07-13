# Anime Recommender — Secure App Deploy Pipeline (DevSecOps + LLMSecOps)

> Design spec for `.github/workflows/app-deploy.yml`. **Nothing here is applied yet.**
> Mirrors the conventions already used by `infra-build.yml` and `vllm-deploy.yml`
> (parallel source gates → build → policy → approval-gated deploy, WIF keyless auth,
> SARIF to the Security tab, `production` environment approval).

---

## 1. Prepare the app to serve from vLLM (do this first)

The app talks to vLLM over the OpenAI-compatible API in `src/llm_provider.py` (`ChatOpenAI`).
Two config values still point at the **old minikube** setup and must change for prod:

| Setting | Current default (`config/config.py`) | Production value |
|---|---|---|
| `VLLM_BASE_URL` | `http://vllm-server.default.svc.cluster.local:8000/v1` | `http://vllm-router-service.default.svc.cluster.local:80/v1` |
| `VLLM_MODEL_NAME` | `HuggingFaceTB/SmolLM2-135M-Instruct` | `Qwen/Qwen2.5-3B-Instruct` |

Source of truth: `k8s/production-stack/values-cpu.yaml` (`modelURL: Qwen/Qwen2.5-3B-Instruct`,
router service on port `80`). These are injected as **env vars** in the app Deployment — not
baked into the image — so the same image works against any backend.

- `LLM_PROVIDER=vllm` stays the default; no API key needed (`api_key="not-needed"` stays).
- Promote `k8s-local/app-deployment.yaml` → a prod manifest at `k8s/app/` with the hardening
  in §4 (the local one runs as root, `imagePullPolicy: Never`, no probes — not prod-safe).
- Set the two env vars above in that Deployment so the app points at the vLLM router.

**Manual verification before any CI:** deploy once by hand, then from inside the app pod
`curl http://vllm-router-service.default.svc.cluster.local:80/v1/models` to confirm the model
name matches, and run one recommendation query end-to-end. Only wire the pipeline once this works.

---

## 2. Pipeline shape (mirrors `infra-build.yml`)

```
                    ┌─────────────── STAGE 1: parallel source gates ───────────────┐
 push / PR ────────▶│  lint-test   pip-audit   gitleaks   bandit   hadolint        │
 (app/**, src/**,   └──────────────────────────────┬───────────────────────────────┘
  k8s/app/**,                                       ▼
  dockerfile)                        STAGE 2: build + image scan (Trivy) + SBOM/sign
                                                    │
                                                    ▼
                                     STAGE 3: manifest policy (kubeconform + kube-linter/OPA)
                                                    │
                          ┌─────────────────────────┴───────────── PR stops here ──┐
                          ▼
                 STAGE 4: deploy to GKE  ── environment: production (WAITS FOR APPROVAL)
                          │
                          ▼
                 STAGE 5: post-deploy smoke test + LLMSecOps red-team gate (§5)
```

Triggers (same style as the other workflows):
```yaml
on:
  workflow_dispatch: { inputs: { action: { type: choice, options: [deploy, uninstall] } } }
  push:         { paths: ["app/**","src/**","pipeline/**","config/**","dockerfile","k8s/app/**",".github/workflows/app-deploy.yml"] }
  pull_request: { paths: [ ...same... ] }
```
- **PRs** run stages 1–3 only (no cluster access — never deploy from a PR).
- **push to main / manual dispatch** runs the full chain; deploy waits for approval.
- `permissions:` scoped **per job** — only the deploy job gets `id-token: write`;
  scan jobs get `contents: read` (+ `security-events: write` to upload SARIF).

---

## 3. DevSecOps controls (app + supply-chain axis)

| # | Stage | Control | Tool | Gate |
|---|---|---|---|---|
| D1 | Source | Lint + unit tests | `ruff`, `pytest` | hard fail |
| D2 | Source | Python dependency CVEs | **pip-audit** (`requirements.txt`) | hard fail HIGH/CRITICAL |
| D3 | Source | Secret scanning (full history) | **gitleaks** (reuse infra config) | hard fail |
| D4 | Source | Python SAST | **bandit** (`src/`,`app/`,`pipeline/`) | SARIF, soft-fail first |
| D5 | Source | Dockerfile lint | **hadolint** | soft-fail → hard once clean |
| D6 | Build | Image build, base pinned by digest | Docker Buildx | — |
| D7 | Build | Image CVE + secret + misconfig scan | **Trivy** `--severity HIGH,CRITICAL` | hard fail; SARIF to Security tab |
| D8 | Build | **SBOM** + build provenance | Syft + `actions/attest-build-provenance` | artifact |
| D9 | Build | Sign image (keyless/OIDC) | **cosign** | attestation |
| D10 | Deploy | Manifest schema validation | **kubeconform** (reuse from vllm-deploy) | hard fail |
| D11 | Deploy | Manifest security policy | **kube-linter** / **conftest (OPA)** | hard fail |
| D12 | Deploy | Keyless auth to GCP | **WIF** | — |
| D13 | Deploy | Approval gate | `environment: production` | manual approval |
| D14 | Runtime | Image pulled by **digest**, not tag | manifest | — |

### Image hardening (`dockerfile`)
Current image is single-stage, runs as **root**, unpinned base, ships build tooling + CSVs. Target:
- **Multi-stage**: build the Chroma index + install deps in a builder; copy only venv + app +
  `chroma_db/` into a slim runtime.
- **Non-root** `USER` (uid 10001); drop `build-essential`/`curl` from the final stage.
- **Pin base by digest** (`python:3.10-slim@sha256:...`), kept current via Dependabot.
- Add `.dockerignore` (`venv/`, `.git/`, secrets out of the build context).

### Registry
Push to the existing Artifact Registry repo (from Terraform):
`us-central1-docker.pkg.dev/${GCP_PROJECT_ID}/anime-rec/anime-rec-app`
Tag with the **git SHA**; deploy by **digest**.

---

## 4. Kubernetes hardening (`k8s/app/`)

Prod Deployment + Service + NetworkPolicy, gated by kube-linter/OPA (D11):
- **`securityContext`**: `runAsNonRoot: true`, `runAsUser: 10001`, `allowPrivilegeEscalation: false`,
  `readOnlyRootFilesystem: true`, `capabilities: {drop: [ALL]}`, `seccompProfile: RuntimeDefault`.
- **Resource requests + limits** (keep from local, tune).
- **Probes**: readiness + liveness on the Streamlit health path.
- **NetworkPolicy**: default-deny egress; allow only DNS + the vLLM router service (also an
  LLMSecOps control — blocks data exfiltration from a compromised app).
- **Image** pinned by digest, `imagePullPolicy: IfNotPresent` (not `Never`).
- **Service** `ClusterIP` (not NodePort).

---

## 5. LLMSecOps controls (model / inference axis)

Scan target is an OpenAI-compatible endpoint, so add a thin `security/target_api.py` FastAPI
wrapper exposing the **full RAG chain** (prompt + Chroma + vLLM) on `/v1`, so scanners hit the
real app, not just the raw model.

### OWASP LLM Top 10 → control → tool

| # | Risk | Control | Tool | Where |
|---|---|---|---|---|
| LLM01 | Prompt injection | red-team scan + input guardrail | **promptfoo redteam**, **garak** (`promptinject`,`dan`), **LLM Guard** | CI gate + runtime |
| LLM02 | Sensitive info disclosure | canary + PII output scan | **Rebuff** canary, **promptfoo pii** | CI gate + runtime |
| LLM03 | Supply chain | dep + image + base scan | pip-audit, Trivy, cosign/SBOM | CI (D2/D7/D8) |
| LLM04 | Data / model poisoning | corpus checksum + schema check at index build | pandas checks | build stage |
| LLM05 | Improper output handling | scan/escape output before `st.write` | **LLM Guard** output scanners, garak `xss` | runtime + CI |
| LLM06 | Excessive agency | N/A — no tools/agents (documented) | — | design note |
| LLM07 | System-prompt leakage | leak-replay red-team; no secrets in prompt | garak `leakreplay`, **ps-fuzz** | CI gate |
| LLM08 | Vector/embedding weakness | poisoned-doc test | promptfoo RAG plugins | CI gate |
| LLM09 | Misinformation | hallucination eval on golden set | **promptfoo** `hallucination` | CI gate |
| LLM10 | Unbounded consumption | `max_tokens` cap + rate limit + K8s limits | code + NetworkPolicy + limits | runtime |

### Guardrails + observability (shipped in the app, measured before/after)
- `src/guardrails.py` wraps the chain: **input** scanner (injection/jailbreak + canary),
  **output** scanner (PII/toxicity redaction, safe markdown).
- Baseline first (guardrails off) → enable → re-scan → **prove risk reduction**.
- **Langfuse** callback in `src/recommender.py`: trace every prompt/context/output/latency/cost;
  alert on injection-detector spikes (LLMSecOps lifecycle stage 7 — monitoring).

### Where LLMSecOps sits in the pipeline
- **CI gate (PR + push):** `promptfoo redteam` + fast `garak` probes against the `target_api.py`
  wrapper in an ephemeral job; hard-fail on new HIGH findings vs. the saved baseline.
- **Nightly / manual (`llmsecops.yml`):** deep garak run against the **live** endpoint;
  reports uploaded as artifacts + summarized in the job summary.

---

## 6. Files this pipeline will add

```
.github/workflows/
  app-deploy.yml              # pipeline §2 (DevSecOps stages 1–4 + smoke/LLM gate)
  llmsecops.yml               # nightly/manual deep red-team against live endpoint
  dependabot.yml              # base-image + action SHA + pip updates

k8s/app/
  deployment.yaml            # hardened app Deployment (§4), env → vLLM router
  service.yaml               # ClusterIP
  networkpolicy.yaml         # default-deny egress; allow DNS + vLLM router
  policy/                    # conftest/OPA rules for the manifest gate (D11)

dockerfile                   # rewritten: multi-stage, non-root, digest-pinned
.dockerignore

security/
  target_api.py              # OpenAI-compatible wrapper over the RAG pipeline
  requirements-sec.txt       # fastapi, uvicorn, garak — NOT in the prod image
  promptfoo/promptfooconfig.yaml
  garak/run_garak.sh
  run_scan.sh                # orchestrator: boot target → scan → collect → teardown
  baseline/                  # saved baseline reports (diff target for the CI gate)
  reports/.gitignore

src/guardrails.py            # input/output guardrails
config/config.py             # updated vLLM prod URL + model name (§1)
```

---

## 7. Prerequisites (reuse infra/vLLM plumbing — no new auth)

- GitHub `production` environment with required reviewers (already used).
- Secrets: `WORKLOAD_PROVIDER`, `SERVICE_ACCOUNT`, `GCP_PROJECT_ID` (already set).
- **Grant/verify** the WIF service account `roles/artifactregistry.writer` (to push the image).
- Artifact Registry repo `anime-rec` exists (Terraform) ✅; vLLM router reachable in `default` ✅.

---

## 8. Rollout order

1. **Wire + harden** — fix `config.py` (§1), rewrite `dockerfile` + `.dockerignore`,
   create `k8s/app/` manifests. **Deploy once manually, confirm app ↔ vLLM works.**
2. **DevSecOps pipeline** — `app-deploy.yml` stages 1–4. Green on a PR.
3. **LLMSecOps baseline** — `security/target_api.py` + promptfoo/garak; run once, save baseline.
4. **LLMSecOps gate** — add red-team job to `app-deploy.yml` (diff vs baseline) + `llmsecops.yml` nightly.
5. **Guardrails + observability** — `src/guardrails.py` + Langfuse; re-scan, prove reduction.

### Open decisions
1. **CI red-team backend** — cheap **Groq**, a tiny local model, or the **real vLLM** endpoint?
2. **Deploy trigger** — auto on merge to `main` (still approval-gated), or manual dispatch only?
