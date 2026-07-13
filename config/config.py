import os
from dotenv import load_dotenv

load_dotenv()

# "vllm" (default, self-hosted on minikube) or "groq" (hosted fallback for local UI iteration)
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "vllm")

# vLLM (OpenAI-compatible) settings - defaults match the GKE production-stack
# (k8s/production-stack/values-cpu.yaml): router service on port 80, serving Qwen2.5-3B.
VLLM_BASE_URL = os.getenv("VLLM_BASE_URL", "http://vllm-router-service.default.svc.cluster.local:80/v1")
VLLM_MODEL_NAME = os.getenv("VLLM_MODEL_NAME", "Qwen/Qwen2.5-3B-Instruct")

# Groq settings (only needed when LLM_PROVIDER=groq)
GROQ_API_KEY = os.getenv("GROQ_API_KEY")
GROQ_API_URL = os.getenv("GROQ_API_URL")
MODEL_NAME = "llama-3.1-8b-instant"

