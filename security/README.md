# security/ — LLMSecOps scanning suite

One home for the LLM security scanners. Committed (versioned, CI-runnable) but
`.dockerignore`d so it never ships in the app image. Scan **outputs** go to
gitignored `reports/` folders — results enumerate weak spots and must not be committed.

Tools today, by stage:

| Stage | Tool | Target |
|---|---|---|
| **deploy gate — app** (RAG + prompt + LLM) | **garak** | the app's `/recommend` endpoint |
| **deploy gate — model** (the LLM behind the app) | **promptfoo** (CyberSecEval) | Groq / vLLM chat endpoint |
| **design-time — prompt hardening** | **ps-fuzz** | the system prompt on the app's model (Groq) — run by hand, not a gate |

## Layout

```
security/
├── targets/                 # local-vs-cloud model switch (used by garak's model modes + promptfoo)
│   ├── local.env            #   → Groq  llama-3.1-8b-instant
│   └── cloud.env            #   → vLLM router  Qwen/Qwen2.5-3B-Instruct
├── garak/
│   ├── run.sh               #   app | local | cloud   (app = tests the recommender)
│   ├── rest_app.tmpl.json   #   REST-generator config template ($APP_URL injected at run time)
│   └── GARAK_GUIDE.md       #   full garak reference
├── promptfoo/
│   └── cyberseceval/        #   Meta CyberSecEval prompt-injection benchmark (promptfoo)
└── ps-fuzz/
    ├── run.sh               #   score/harden the system prompt (design-time, Groq-backed)
    └── sysprompt.txt        #   the app's system prompt under test (mirrors prompt_template.py)
```

## garak — test the app (the main use case)

garak attacks the app over HTTP, so the app must expose `/recommend`
(`app/api.py`, run with `uvicorn app.api:app`). Then:

```bash
source llmsec/bin/activate     # the garak venv
# point at wherever the app runs; default is http://127.0.0.1:8600/recommend
APP_URL=http://127.0.0.1:8600/recommend PROBES=promptinject security/garak/run.sh app
```

garak auto-writes `garak/reports/garak-app.report.html` at the end.
Knobs: `PROBES=...` (attack set), `PARALLEL=8` (concurrency). See `garak/GARAK_GUIDE.md`.

Model-layer comparison (optional): `run.sh local` / `run.sh cloud` hit the bare model.

## promptfoo — test the model behind the app

```bash
cd security/promptfoo/cyberseceval
set -a; . ../../../.env; set +a          # GROQ_API_KEY (target + judge)
npx promptfoo@latest eval --filter-providers local-groq --filter-sample 25 -o reports/report.html
```

## Choosing local vs cloud

Both `run.sh local/cloud` and promptfoo's `--filter-providers` read the same idea:
`local` = Groq, `cloud` = the vLLM router (port-forward it, or set `CLOUD_BASE_URL`):
```bash
kubectl port-forward svc/vllm-router-service 8000:80 -n default
```

## Same files in CI

`.github/workflows/llmsecops.yml` runs the *same* configs against the app on GKE —
promptfoo (model) + garak (app) — so local and CI never drift.
