# Local vLLM + llm-d on minikube (free, GPU-less learning pass)

## Context

Before spending any of the $300 GCP credit or waiting on GPU quota (see `DEPLOYMENT_PLAN.md`), learn vLLM and llm-d **by doing**, on minikube, for $0, with no GPU — and have the actual Streamlit app talk to the locally-served model, not just prove the infra works in isolation.

This machine has **no NVIDIA GPU** (`nvidia-smi` not found), so this pass uses a small CPU-friendly model (Qwen2.5-0.5B-Instruct) instead of Llama-3.1-8B. The point isn't model quality — it's learning the exact same control-plane objects (`InferencePool`/`InferenceModel`/`Gateway`/`HTTPRoute`) and the exact same app-side wiring (`ChatOpenAI` against an OpenAI-compatible endpoint) that you'll reuse verbatim on GKE with a real GPU and the full-size model later. Phase F maps every local piece to its GCP equivalent.

**Sequencing now matters:** vLLM (Phase B) and the llm-d Gateway (Phase C) must be up and healthy *before* the app (Phase D) can return a real recommendation, since the app talks to them directly. If you want an always-working demo regardless of backend state, keep the Groq path alive as a fallback (`LLM_PROVIDER=groq` — see Phase D) rather than treating it as a separate deployment track.

Verified local environment: 14 cores, 15GB RAM, AVX2, 913GB free disk, Docker Engine 29.5.3, minikube v1.38.1 (stopped), `kubectl`/`helm` not yet installed.

## Model choice: Qwen2.5-0.5B-Instruct

Llama-3.1-8B needs ~16GB of RAM just for fp16 weights — won't comfortably fit in 15GB total alongside minikube + the OS, and CPU decoding at that size would be painfully slow. **Qwen2.5-0.5B-Instruct** is the smallest instruct model in the Qwen2.5 family — ungated (no HF license click-through, no token needed), ~1GB in fp16, minimal RAM/CPU footprint, and (unlike more obscure tiny models) extremely well-tested with vLLM specifically, so compatibility risk is low. Output quality at this size is rough — that's expected and irrelevant here, since this pass is about proving the vLLM/llm-d pipeline works, not about answer quality. If you want better generations later, `Qwen/Qwen2.5-1.5B-Instruct` is the natural step up — same steps, just a bigger `--local-dir`/`--model` value and a bit more RAM.

## Caveats to verify when we execute (things move fast, don't trust these blindly)

- **vLLM CPU image**: vLLM's GPU image (`vllm/vllm-openai`) won't run without a GPU. There's an official CPU build path (`docker/Dockerfile.cpu` in the vLLM repo) but I haven't confirmed today's published tag — we'll check `docs.vllm.ai` / Docker Hub right before Phase B and build locally from source if no current public tag exists.
- **Local Gateway controller**: GKE's managed Gateway (used in `DEPLOYMENT_PLAN.md`) doesn't exist on minikube. llm-d's own local quickstart commonly points at **kgateway** (Envoy-based, CNCF, supports the Gateway API Inference Extension) — we'll confirm the exact Helm repo/chart name from `llm-d.ai/docs` at that step.
- **llm-d chart names/versions** — same caveat as the GCP plan, verify at execution time.

---

## Phase A — Local tooling + minikube up

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# start minikube — give it real headroom for CPU inference (host has 14 cores/15GB)
minikube start --driver=docker --cpus=8 --memory=10000mb --disk-size=40g
kubectl get nodes

kubectl create namespace anime-rec
```

---

## Phase B — Serve Qwen2.5-1.5B via vLLM (CPU) inside minikube

**Model weights → PVC, not baked into an image.** This is the exact same pattern as the GCS bucket in the GCP plan — weights live outside the serving container and get mounted at runtime — just using minikube's default hostPath-backed `PersistentVolumeClaim` instead of the GCS FUSE CSI driver.

`k8s-local/model-pvc.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-weights
  namespace: anime-rec
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests: {storage: 10Gi}
```

`k8s-local/download-model-job.yaml` — one-shot Job, no HF token needed (ungated model):
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: download-model
  namespace: anime-rec
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: downloader
          image: python:3.11-slim
          command: ["bash", "-c"]
          args:
            - |
              pip install -U "huggingface_hub[cli]" --quiet
              huggingface-cli download Qwen/Qwen2.5-0.5B-Instruct \
                --local-dir /models/qwen2.5-0.5b-instruct
          volumeMounts: [{name: models, mountPath: /models}]
      volumes:
        - name: models
          persistentVolumeClaim: {claimName: model-weights}
```
```bash
kubectl apply -f k8s-local/model-pvc.yaml
kubectl apply -f k8s-local/download-model-job.yaml
kubectl -n anime-rec wait --for=condition=complete job/download-model --timeout=15m
```

`k8s-local/vllm-deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: vllm, namespace: anime-rec}
spec:
  replicas: 1
  selector: {matchLabels: {app: vllm}}
  template:
    metadata: {labels: {app: vllm}}
    spec:
      containers:
        - name: vllm
          image: <vllm-cpu-image>   # confirm/build at execution time, see caveats above
          env:
            - {name: VLLM_CPU_KVCACHE_SPACE, value: "2"}   # vLLM's CPU backend needs this set explicitly
          args:
            - --model=/mnt/models/qwen2.5-0.5b-instruct
            - --served-model-name=qwen2.5-0.5b-instruct
            - --max-model-len=4096
          resources:
            requests: {cpu: "2", memory: "3Gi"}
            limits: {cpu: "4", memory: "4Gi"}
          ports: [{containerPort: 8000}]
          volumeMounts: [{name: models, mountPath: /mnt/models, readOnly: true}]
      volumes:
        - name: models
          persistentVolumeClaim: {claimName: model-weights}
---
apiVersion: v1
kind: Service
metadata: {name: vllm, namespace: anime-rec}
spec:
  selector: {app: vllm}
  ports: [{port: 8000, targetPort: 8000}]
```

**Verify:**
```bash
kubectl -n anime-rec port-forward svc/vllm 8000:8000 &
curl localhost:8000/v1/chat/completions -H "Content-Type: application/json" -d \
  '{"model":"qwen2.5-0.5b-instruct","messages":[{"role":"user","content":"say hi"}]}'
```

---

## Phase C — Install llm-d's Inference Gateway on top

```bash
# Gateway API + Inference Extension CRDs — same as GCP plan
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/manifests.yaml

# Local Gateway controller (kgateway, or whatever llm-d's docs currently point at — verify)
helm repo add kgateway https://kgateway-dev.github.io/kgateway
helm install kgateway kgateway/kgateway -n kgateway-system --create-namespace

# llm-d scheduler
helm repo add llm-d https://llm-d.ai/charts
helm install llm-d-scheduler llm-d/llm-d-inference-scheduler -n llm-d --create-namespace
```

`k8s-local/llm-d.yaml`:
```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferencePool
metadata: {name: vllm-pool, namespace: anime-rec}
spec:
  targetPortNumber: 8000
  selector: {app: vllm}
  extensionRef: {name: llm-d-scheduler}
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata: {name: qwen2-5-0-5b, namespace: anime-rec}
spec:
  modelName: qwen2.5-0.5b-instruct
  poolRef: {name: vllm-pool}
  criticality: Critical
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: inference-gateway, namespace: anime-rec}
spec:
  gatewayClassName: kgateway   # confirm exact class name once kgateway is installed
  listeners: [{name: http, port: 80, protocol: HTTP}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: vllm-route, namespace: anime-rec}
spec:
  parentRefs: [{name: inference-gateway}]
  rules:
    - backendRefs:
        - {group: inference.networking.x-k8s.io, kind: InferencePool, name: vllm-pool}
```

**Verify:** `kubectl -n anime-rec get gateway,httproute,inferencepool` all show Ready/Accepted, then repeat the `curl` from Phase B against the Gateway's ClusterIP instead of the raw `vllm` Service — same response, different route.

---

## Phase D — Wire the app to the local vLLM + llm-d Gateway

The app now calls the local Qwen model through the Gateway from Phase C, via the same `ChatOpenAI`-against-an-OpenAI-compatible-endpoint pattern you'll reuse on GCP in `DEPLOYMENT_PLAN.md` Phase 1.8 — only the URL and model name change there.

### Code changes
- `config/config.py`: fix the pre-existing bug (`GROQ_API_KEY` is imported by `pipeline/pipeline.py:3` but never defined — `ImportError`s today regardless of provider) and add the provider switch:
  ```python
  LLM_PROVIDER = os.getenv("LLM_PROVIDER", "vllm")   # "vllm" or "groq"
  VLLM_BASE_URL = os.getenv("VLLM_BASE_URL", "http://inference-gateway.anime-rec.svc.cluster.local/v1")
  VLLM_MODEL_NAME = os.getenv("VLLM_MODEL_NAME", "qwen2.5-0.5b-instruct")
  GROQ_API_KEY = os.getenv("GROQ_API_KEY")   # only needed if LLM_PROVIDER=groq
  ```
- New `src/llm_provider.py` — factory so the backend is a one-line env var flip, not a code change:
  ```python
  from langchain_openai import ChatOpenAI
  from langchain_groq import ChatGroq
  from config.config import LLM_PROVIDER, VLLM_BASE_URL, VLLM_MODEL_NAME, GROQ_API_KEY, MODEL_NAME

  def get_llm():
      if LLM_PROVIDER == "groq":
          return ChatGroq(api_key=GROQ_API_KEY, model=MODEL_NAME, temperature=0)
      return ChatOpenAI(
          base_url=VLLM_BASE_URL,
          api_key="not-needed",   # vLLM ignores this; langchain_openai just requires a non-empty string
          model=VLLM_MODEL_NAME,
          temperature=0,
      )
  ```
- `src/recommender.py`: replace the direct `ChatGroq(...)` construction with `self.llm = get_llm()`.
- `requirements.txt`: add `langchain-openai`.

### K8s changes
Build the app image straight into minikube's Docker daemon (no registry needed):
```bash
eval $(minikube docker-env)
docker build -t anime-rec-app:local .
```

`k8s-local/app-deployment.yaml` — the existing `k8s.yaml` content, namespaced, pointed at the local image, and defaulted to the vLLM provider:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: anime-rec-app, namespace: anime-rec}
spec:
  replicas: 1
  selector: {matchLabels: {app: anime-rec}}
  template:
    metadata: {labels: {app: anime-rec}}
    spec:
      containers:
        - name: app
          image: anime-rec-app:local
          imagePullPolicy: Never
          ports: [{containerPort: 8501}]
          env:
            - {name: LLM_PROVIDER, value: "vllm"}
            - {name: VLLM_BASE_URL, value: "http://inference-gateway.anime-rec.svc.cluster.local/v1"}
            - {name: VLLM_MODEL_NAME, value: "qwen2.5-0.5b-instruct"}
---
apiVersion: v1
kind: Service
metadata: {name: anime-rec-service, namespace: anime-rec}
spec:
  type: NodePort
  selector: {app: anime-rec}
  ports: [{port: 80, targetPort: 8501}]
```

**Confirm before applying:** the Gateway controller (kgateway) creates its own fronting `Service` once the `Gateway` resource in Phase C is `Programmed: True` — run `kubectl get svc -n anime-rec` at that point and correct `VLLM_BASE_URL` if the actual Service name differs from `inference-gateway`.

Optional, only if you want the Groq fallback available: `kubectl create secret generic llmops-secrets --from-literal=GROQ_API_KEY=<your-groq-key> -n anime-rec`, then add `envFrom: [{secretRef: {name: llmops-secrets}}]` alongside the `env:` block above, and flip `LLM_PROVIDER` to `"groq"` when you want it.

---

## Phase E — Verify the full flow end-to-end

Sanity-check the backend directly first, same as Phase C's verify step, before trusting the UI:
```bash
kubectl -n anime-rec port-forward svc/inference-gateway 8080:80 &
curl localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d \
  '{"model":"qwen2.5-0.5b-instruct","messages":[{"role":"user","content":"say hi"}]}'
```

Then the real flow:
```bash
minikube service anime-rec-service -n anime-rec   # opens the Streamlit UI
```
Submit a real query ("light hearted anime with school settings"). Expect a rough, sometimes incoherent answer — that's the 0.5B model, not a bug; the point is that a response comes back through the whole chain at all. Cross-check:
```bash
kubectl -n anime-rec logs deploy/vllm                          # request landed on vLLM
kubectl -n llm-d logs deploy/llm-d-scheduler                   # scheduler's routing decision through the InferencePool
```
If nothing comes back, work backwards through the chain: Gateway curl (Phase C) → direct vLLM curl (Phase B) → `kubectl logs` on the app pod for a connection error to `VLLM_BASE_URL`.

---

## Phase F — What carries over to GCP, and what changes

| Local (minikube, track 2) | GCP (`DEPLOYMENT_PLAN.md`) |
|---|---|
| PVC + download Job | GCS bucket + Cloud Storage FUSE CSI driver |
| `vllm-cpu` image, Qwen2.5-0.5B | `vllm/vllm-openai`, Llama-3.1-8B, GPU nodeSelector |
| `kgateway` GatewayClass | `gke-l7-rilb` GatewayClass (GKE-managed) |
| `InferencePool`/`InferenceModel`/`HTTPRoute` YAML | **identical**, no changes |
| minikube single node | `e2-small` pool + `gpu-pool` (spot, min=0/max=1) |

Everything in Phase C's `llm-d.yaml` is portable as-is, and so is Phase D's app wiring — `src/llm_provider.py` and the `ChatOpenAI` swap already happened here, not deferred to GCP. On GCP (`DEPLOYMENT_PLAN.md` Phase 1.8), the only changes are the `VLLM_BASE_URL`/`VLLM_MODEL_NAME` values (real Gateway address, `llama-3.1-8b-instruct`) — the code path itself is already proven end-to-end by this local pass.
