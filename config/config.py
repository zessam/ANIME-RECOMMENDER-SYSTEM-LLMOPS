import os
from dotenv import load_dotenv

load_dotenv()

# "vllm" (default, self-hosted on minikube) or "groq" (hosted fallback for local UI iteration)
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "vllm")

# vLLM (OpenAI-compatible) settings - defaults match the GKE production-stack
# (k8s/production-stack/values-cpu.yaml): router service on port 80, serving Qwen2.5-3B.
VLLM_BASE_URL = os.getenv("VLLM_BASE_URL", "http://vllm-router-service.default.svc.cluster.local:80/v1")
VLLM_MODEL_NAME = os.getenv("VLLM_MODEL_NAME", "Qwen/Qwen2.5-3B-Instruct")

# Qwen2.5-3B in float32 on 4 vCPU generates a few tokens/sec, so a 512-token answer
# legitimately takes minutes -- hence 300s rather than the openai client's 600s default.
VLLM_TIMEOUT = float(os.getenv("VLLM_TIMEOUT", "300"))
# The openai client retries twice by default, which turns one timeout into ~3x the
# wall clock. A slow endpoint does not get faster on retry; only retry once.
VLLM_MAX_RETRIES = int(os.getenv("VLLM_MAX_RETRIES", "1"))

# Groq settings (only needed when LLM_PROVIDER=groq)
GROQ_API_KEY = os.getenv("GROQ_API_KEY")
GROQ_API_URL = os.getenv("GROQ_API_URL")
MODEL_NAME = "llama-3.1-8b-instant"

