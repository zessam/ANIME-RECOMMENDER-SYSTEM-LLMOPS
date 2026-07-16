#!/usr/bin/env bash
# Garak red-team.  Requires the garak venv:  source ~/.secops-garak/bin/activate
#
# Usage:
#   ./run.sh app      # attack the REAL app (RAG + prompt) via the HTTP wrapper  <-- tests YOUR app
#   ./run.sh local    # attack the bare Groq model  (llama-3.1-8b-instant)
#   ./run.sh cloud    # attack the bare vLLM router (Qwen2.5-3B)
#
# app mode targets $APP_URL, injected at fire time (default = local wrapper):
#   APP_URL=http://127.0.0.1:8600/recommend  ./run.sh app        # local app server
#   APP_URL=https://<your-host>/recommend    ./run.sh app        # deployed app
#
# For the local default, start the app API FIRST in another terminal (app venv):
#   source .appvenv/bin/activate && uvicorn app.api:app --host 127.0.0.1 --port 8600
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TARGET="${1:-app}"
PROBES="${PROBES:-promptinject,dan.DanInTheWild}"   # override: PROBES=promptinject ./run.sh app
PARALLEL="${PARALLEL:-8}"                            # concurrent attempts (each is a real app call)

mkdir -p "$HERE/reports"

case "$TARGET" in
  app)
    # garak POSTs each probe to $APP_URL; the app runs retriever + prompt + Groq.
    APP_URL="${APP_URL:-http://127.0.0.1:8600/recommend}"
    echo ">> garak vs the ANIME APP (RAG) @ ${APP_URL}"
    curl -sf -X POST "$APP_URL" \
      -H 'Content-Type: application/json' -d '{"prompt":"ping"}' >/dev/null \
      || { echo "!! app not reachable at ${APP_URL}. Start it: source .appvenv/bin/activate && uvicorn app.api:app --host 127.0.0.1 --port 8600"; exit 1; }
    # inject the URL into the rest-generator config at fire time
    GEN="$HERE/reports/rest_app.gen.json"
    sed "s|__APP_URL__|${APP_URL}|g" "$HERE/rest_app.tmpl.json" > "$GEN"
    garak --model_type rest -G "$GEN" \
      --probes "$PROBES" --generations 1 \
      --parallel_attempts "$PARALLEL" \
      --report_prefix "$HERE/reports/garak-app"
    ;;
  local|cloud)
    # repo secrets (GROQ_API_KEY) then the chosen target profile
    set -a; . "$ROOT/.env"; . "$HERE/../targets/${TARGET}.env"; set +a
    export OPENAI_API_KEY="$TARGET_API_KEY"
    export OPENAI_BASE_URL="$TARGET_BASE_URL"
    echo ">> garak vs ${TARGET_LABEL} (${TARGET_MODEL}) @ ${TARGET_BASE_URL}  [bare model]"
    garak --model_type openai --model_name "$TARGET_MODEL" \
      --probes "$PROBES" --generations 1 \
      --parallel_attempts "$PARALLEL" \
      --report_prefix "$HERE/reports/garak-${TARGET_LABEL}"
    ;;
  *)
    echo "usage: ./run.sh [app|local|cloud]"; exit 2 ;;
esac
