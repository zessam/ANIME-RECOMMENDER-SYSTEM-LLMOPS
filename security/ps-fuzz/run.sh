#!/usr/bin/env bash
# ps-fuzz 2 — hardens the app's SYSTEM PROMPT (design-time; NOT a deploy gate).
#
# It does NOT hit the app's /recommend endpoint. It sends (your system prompt +
# generated attacks) to the SAME MODEL the local app uses (Groq), and scores how
# resilient the prompt is per attack category (BROKEN / RESILIENT + overall score).
# "Against your local app" = same system prompt (sysprompt.txt, mirrors
# prompt_template.py) + same model (llama-3.1-8b-instant).
#
# Install once in a dedicated venv (its langchain pin clashes with the app/garak):
#   python3 -m venv ~/.secops-psfuzz && source ~/.secops-psfuzz/bin/activate
#   pip install prompt-security-fuzzer
#
# Usage:  source ~/.secops-psfuzz/bin/activate && security/ps-fuzz/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# Groq creds — the model the local app uses. ps-fuzz uses the OpenAI-compatible
# client, so we route it to Groq via the base-url env vars.
set -a; . "$ROOT/.env"; set +a
export OPENAI_API_KEY="$GROQ_API_KEY"
export OPENAI_API_BASE="https://api.groq.com/openai/v1"
export OPENAI_BASE_URL="https://api.groq.com/openai/v1"

TARGET_MODEL="${TARGET_MODEL:-llama-3.1-8b-instant}"       # the app's model (defended)
ATTACK_MODEL="${ATTACK_MODEL:-llama-3.3-70b-versatile}"    # stronger model to generate attacks
ATTEMPTS="${ATTEMPTS:-3}"

echo ">> ps-fuzz: hardening the app system prompt on ${TARGET_MODEL} (attacker: ${ATTACK_MODEL})"

# ps-fuzz has NO report-file option — it only prints the resilience matrix to the
# terminal (+ a debug prompt-security-fuzzer.log). Capture the matrix ourselves.
mkdir -p "$HERE/reports"
REPORT="$HERE/reports/psfuzz-$(date +%Y%m%d-%H%M%S).txt"

# NOTE: ps-fuzz CLI flags drift between versions. If these are rejected, run
# `prompt-security-fuzzer --help` (and `--list-providers`) and adjust names.
prompt-security-fuzzer \
  -b \
  --target-provider open_ai --target-model "$TARGET_MODEL" \
  --attack-provider open_ai --attack-model "$ATTACK_MODEL" \
  -n "$ATTEMPTS" \
  "$HERE/sysprompt.txt" 2>&1 | tee "$REPORT"

echo ""
echo ">> resilience matrix saved to: $REPORT"
echo ">> full debug log: $HERE/prompt-security-fuzzer.log"
