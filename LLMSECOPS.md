# LLMSecOps pipeline

Security red-teaming for the deployed vLLM model, wired into Grafana.

Two workflows:
- **`.github/workflows/llmsecops.yml`** — one **job per tool** (8 separate stages);
  each calls the reusable stage with a different `stage` input.
- **`.github/workflows/llmsecops-stage.yml`** — the reusable stage: authenticates to
  GKE (keyless WIF), **port-forwards** the router (`vllm-router-service:80` →
  `localhost:8000`), runs the scanner, **pushes results to the Pushgateway** (→
  Prometheus → Grafana), and uploads the report artifact.

| Stage (job) | Goal | Scanner | Grafana |
|-------------|------|---------|---------|
| `prompt-security` | injection / jailbreak / leakage | **Promptfoo** | ✅ metrics pushed |
| `llm-vuln` | broad AI red team | **Garak** | ✅ metrics pushed |
| `agent-security` | tool abuse / multi-step | **Agentic Security** | report only |
| `prompt-fuzz` | system prompt fuzzing | **ps-fuzz 2** | report only |
| `io-rag-scan` | context + I/O scan | **LLM-Guard** | report only |
| `model-fingerprint` | substituted-model detection | **LLMmap** | report only |
| `privacy` | confidential-info exposure | **LLM Confidentiality** | report only |
| `policy-compliance` | policy + moderation | **Purple Llama** | report only |

## Run it
**Actions → LLMSecOps → Run workflow** → pick `stage` (`all` or one) → **approve the
`production` gate**. Reports are under the run's **Artifacts**; Garak/Promptfoo numbers
also land in Grafana.

- Manual only; each stage is gated by `production` (uses your existing WIF secrets).
- `all` runs every stage in parallel — note each waits for its own approval (secrets
  are environment-scoped). Run a single stage to approve once.

## Grafana wiring
Garak + Promptfoo results are parsed and pushed to the **Pushgateway** (from the
observability stack) under `job="llmsecops"`, labelled by `stage`. Prometheus scrapes
it → build a **security panel** in Grafana:

| Panel | PromQL |
|-------|--------|
| Garak pass rate | `llmsecops_garak_pass_rate` |
| Garak failures (hits) | `llmsecops_garak_failures` |
| Promptfoo attack failures | `llmsecops_promptfoo_failures` |
| Promptfoo pass rate | `llmsecops_promptfoo_pass_rate` |
| Last run per stage | `llmsecops_stage_last_run` |

> Requires the observability stack deployed (Pushgateway reachable). If it isn't, the
> scan still runs + uploads its report; the push step just logs "push skipped".

## Prerequisites
- vLLM engine `1/1 Ready` and the router serving.
- Observability stack deployed (for the Grafana push).
- `production` secrets: `WORKLOAD_PROVIDER`, `SERVICE_ACCOUNT`, `GCP_PROJECT_ID`.

## Honest caveats
- **Garak & Promptfoo** are wired end-to-end (run → parse → Grafana). The other five
  (`agent-security`, `prompt-fuzz`, `model-fingerprint`, `privacy`, `policy-compliance`)
  are **templates** — they install/clone the tool and leave a `TUNE:` note where you
  pick attacks/flags. They upload their console output as artifacts.
- **CPU is slow.** Scopes are tiny (`numTests: 3`, `--generations 1`); full red-team
  runs take hours and load the paid serve node. Run, collect, done.
