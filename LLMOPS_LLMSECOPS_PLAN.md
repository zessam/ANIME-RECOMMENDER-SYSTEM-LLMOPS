# Anime Recommender — LLMOps + LLMSecOps Plan

## 0. What this project is (current state)
LangChain RAG app:
`Streamlit (app/app.py)` → `AnimeRecommendationPipeline` → `RetrievalQA (src/recommender.py)`
→ `Chroma vector store (src/vector_store.py, HuggingFace embeddings)`
→ LLM backend chosen at runtime in `src/llm_provider.py` (**vLLM** on minikube, or **Groq**).
Data: CSV → `src/data_loader.py` → `pipeline/build_pipeline.py`. Ships via `dockerfile` → `k8s-local/`.

Two layers to build:
- **LLMOps** = build/deploy/operate the app reliably (data → index → serve → monitor).
- **LLMSecOps** = security controls + adversarial testing at each LLMOps stage (OWASP LLM Top 10).

---

# PART A — LLMOps Pipeline

Lifecycle stage → what exists → what to add → tool.

| Stage | Exists | Add | Tool |
|-------|--------|-----|------|
| 1. Data ingestion | `data_loader.py` (CSV) | schema + row validation, checksum | pandas, `great_expectations` (opt) |
| 2. Indexing / embeddings | `vector_store.py`, `build_pipeline.py` | versioned index build, reproducible | Chroma, HuggingFace embeddings |
| 3. Model serving | `llm_provider.py` (vLLM/Groq) | health checks, model version pinning | vLLM, Groq |
| 4. RAG chain | `recommender.py`, `prompt_template.py` | prompt versioning | LangChain |
| 5. App serving | `app.py` (Streamlit) | caching (has `@st.cache_resource`) | Streamlit |
| 6. Containerize | `dockerfile` | non-root user, multi-stage build | Docker |
| 7. Deploy | `k8s-local/*.yaml` | probes, resource limits (has some) | minikube / k8s |
| 8. CI/CD | — | build → test → scan → deploy | GitHub Actions |
| 9. Eval / quality | — | RAG answer quality tests | **promptfoo eval**, ragas (opt) |
| 10. Observability | — | tracing, latency, cost, prompt logs | **Langfuse** |

### LLMOps additions to build
```
ops/
  eval/
    promptfoo_eval.yaml     # golden-set: does it recommend 3 anime, on-topic, no hallucination
    golden_queries.csv      # test prompts + expected traits
  observability/
    langfuse_setup.md       # self-host or cloud; wrap recommender with Langfuse callback
.github/workflows/
  ci.yml                    # lint + build image + run promptfoo eval on PR
  cd.yml                    # push image + apply k8s manifests (manual/tagged)
```
- **Langfuse**: add its LangChain callback handler in `src/recommender.py` so every
  query logs prompt, retrieved context, output, latency, and cost.
- **promptfoo eval** (different mode from redteam): assert response quality on a golden set.

---

# PART B — LLMSecOps Pipeline (OWASP LLM Top 10)

### Core design: one OpenAI-compatible target for BOTH surfaces
Scanners attack an OpenAI-style HTTP endpoint. Raw vLLM already is one; Streamlit isn't.
Add a thin FastAPI wrapper so the SAME scanner config hits either surface by URL swap:
- `:8000/v1` → raw model (SmolLM2, no RAG)
- `:8600/v1` → full app (prompt template + Chroma + LLM)
Backend stays provider-agnostic (inherits `LLM_PROVIDER` from `config.py`).

### OWASP LLM Top 10 → location here → tool
| # | Risk | Where in repo | Tool |
|---|------|---------------|------|
| LLM01 | Prompt Injection | query → `recommender.py` | promptfoo redteam, garak `promptinject`/`dan`, ps-fuzz |
| LLM02 | Sensitive Info Disclosure | Groq key, leaked context | promptfoo `pii`, Rebuff canary |
| LLM03 | Supply Chain | `requirements.txt`, image | pip-audit, Trivy |
| LLM04 | Data & Model Poisoning | CSV → `vector_store.py` | build-time checksum + schema check |
| LLM05 | Improper Output Handling | `st.write` markdown | garak `xss`, LLM Guard output scanners |
| LLM06 | Excessive Agency | N/A (no tools) | documented not-applicable |
| LLM07 | System Prompt Leakage | `prompt_template.py` | garak `leakreplay`, ps-fuzz |
| LLM08 | Vector/Embedding Weakness | Chroma retrieval | promptfoo RAG plugins + poisoned-doc test |
| LLM09 | Misinformation | fabricated titles | promptfoo `hallucination` |
| LLM10 | Unbounded Consumption | no token/rate cap | promptfoo + code fix |

### LLMSecOps additions to build
```
security/
  target_api.py            # OpenAI-compatible FastAPI wrapper → pipeline.recommend()
  requirements-sec.txt     # fastapi, uvicorn, garak (promptfoo via npx), pip-audit
  run_scan.sh              # boot target → run promptfoo + garak → collect reports → teardown
  promptfoo/
    promptfooconfig.yaml   # redteam: plugins owasp:llm + pii + hallucination; both targets
  garak/
    run_garak.sh           # probes: promptinject, dan, leakreplay, xss, encoding
  reports/.gitignore
  OWASP_LLM_MAPPING.md
  README.md
.github/workflows/
  llmsecops.yml            # pip-audit + Trivy gate on PR; redteam nightly/manual
```
- `requirements-sec.txt` is SEPARATE from app `requirements.txt` so scanners never ship
  in the prod image.
- Defenses (LLM Guard / Rebuff in a new `src/guardrails.py`) come AFTER the first scan,
  so you measure risk reduction against a baseline.

---

# What to do — execution roadmap

## Phase 0 — Prereqs (once)
1. Build the index: `python pipeline/build_pipeline.py` (creates `chroma_db/`).
2. Pick a backend: `export LLM_PROVIDER=groq` + `GROQ_API_KEY` (fast) OR minikube+vLLM (prod-parity).
3. Have Node.js (for `npx promptfoo`) and a Python venv.

## Phase 1 — LLMSecOps baseline (fastest to real findings)
- **Step 1** Build `security/target_api.py` → verify `curl :8600/health` + a chat completion.
- **Step 2** Build `promptfoo/promptfooconfig.yaml` → `npx promptfoo@latest redteam run -c ...`
  → OWASP pass/fail report.
- **Step 3** Build `security/garak/run_garak.sh` → deep probes → reports in `security/reports/`.
- **Step 4** Build `security/run_scan.sh` orchestrator → one command runs it all.
- **Step 5** Write `OWASP_LLM_MAPPING.md` + `README.md`.
- **Step 6** Add `.github/workflows/llmsecops.yml` (pip-audit + Trivy gate).
➡ Save Phase 1 reports as your **security baseline**.

## Phase 2 — LLMOps quality + observability
- **Step 7** Add Langfuse callback in `src/recommender.py` → traces/latency/cost.
- **Step 8** Add `ops/eval/promptfoo_eval.yaml` + golden set → quality gate.
- **Step 9** Add `.github/workflows/ci.yml` (lint + build + eval) and `cd.yml` (deploy).

## Phase 3 — Defenses, then re-scan
- **Step 10** Add `src/guardrails.py` (LLM Guard / Rebuff input+output scanners) + harden
  `prompt_template.py` against context injection.
- **Step 11** CSV checksum/schema check in `pipeline/build_pipeline.py` (LLM04).
- **Step 12** k8s `NetworkPolicy` + non-root `securityContext`; non-root `USER` in dockerfile.
- **Step 13** Re-run `security/run_scan.sh` → diff vs baseline → prove risk reduction.

## Suggested order
Phase 1 first (Steps 1→2 give first OWASP findings). Then Phase 2 for operability.
Then Phase 3 to close the gaps and demonstrate before/after.
