"""LLMmap automation — fingerprint the MODEL behind an OpenAI-compatible endpoint.

Detects model substitution/downgrade: it sends LLMmap's discriminative queries to
the target's chat endpoint and predicts which model is serving them.

Targets the RAW model endpoint (Groq /v1 or the vLLM router) — NOT the app's
/recommend, because the RAG prompt + context would corrupt the fingerprint signal.

Env (set by run.sh from targets/*.env):
  LLMMAP_HOME       path to the cloned LLMmap repo (has data/pretrained_models/default)
  TARGET_BASE_URL   OpenAI-compatible base url
  TARGET_MODEL      model id to call
  TARGET_API_KEY    api key (real for Groq; 'dummy' for vLLM)
"""
import os
import sys

LLMMAP_HOME = os.environ["LLMMAP_HOME"]
sys.path.insert(0, LLMMAP_HOME)

from LLMmap.inference import load_LLMmap  # noqa: E402
from openai import OpenAI  # noqa: E402

MODEL_DIR = os.path.join(LLMMAP_HOME, "data", "pretrained_models", "default")
conf, llmmap = load_LLMmap(MODEL_DIR)

client = OpenAI(
    base_url=os.environ["TARGET_BASE_URL"],
    api_key=os.environ.get("TARGET_API_KEY", "dummy"),
)
model = os.environ["TARGET_MODEL"]

print(f"# fingerprinting {model} @ {os.environ['TARGET_BASE_URL']}")
print(f"# sending {len(llmmap.queries)} LLMmap queries...")

answers = []
for i, query in enumerate(llmmap.queries, 1):
    resp = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": query}],
        temperature=0,
    )
    answers.append(resp.choices[0].message.content or "")
    print(f"  [{i}/{len(llmmap.queries)}] done")

print("\n### FINGERPRINT RESULT (closest known models by distance) ###")
llmmap.print_result(llmmap(answers))
