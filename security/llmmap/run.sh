#!/usr/bin/env bash
# LLMmap — fingerprint the MODEL behind an endpoint (detect substitution/downgrade).
# Model-layer tool: targets the raw chat endpoint, NOT the app's /recommend.
#
# One-time setup (its own venv — torch, transformers, openai 1.97):
#   git clone https://github.com/pasquini-dario/LLMmap.git security/llmmap/LLMmap
#   python3 -m venv ~/.secops-llmmap && source ~/.secops-llmmap/bin/activate
#   pip install -r security/llmmap/LLMmap/requirements.txt
#
# Usage:  source ~/.secops-llmmap/bin/activate
#         security/llmmap/run.sh local     # Groq  llama-3.1-8b-instant
#         security/llmmap/run.sh cloud      # vLLM router  Qwen2.5-3B  (port-forward first)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TARGET="${1:-local}"

# repo secrets (GROQ_API_KEY) + the chosen target profile (TARGET_BASE_URL/MODEL/API_KEY)
set -a; . "$ROOT/.env"; . "$HERE/../targets/${TARGET}.env"; set +a
export TARGET_BASE_URL TARGET_MODEL TARGET_API_KEY

# path to the cloned LLMmap repo (holds the pretrained fingerprint model)
export LLMMAP_HOME="${LLMMAP_HOME:-$HERE/LLMmap}"
[ -d "$LLMMAP_HOME/data/pretrained_models/default" ] \
  || { echo "!! LLMmap not found at $LLMMAP_HOME. Clone it (see header)."; exit 1; }

echo ">> LLMmap fingerprint vs ${TARGET_LABEL} (${TARGET_MODEL})"
python "$HERE/fingerprint.py"
