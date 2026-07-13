# Observability & Evaluation — vLLM on Grafana

Three kinds of measurement, one Grafana:

| Source | What it measures | How it reaches Grafana |
|--------|------------------|------------------------|
| **vLLM engine `/metrics`** | live serving: tokens/s, TTFT, e2e latency, queue, cache | Prometheus **scrapes** it |
| **router `/metrics`** | request counts, routing, per-backend stats | Prometheus **scrapes** it |
| **GuideLLM** (perf benchmark) | throughput/latency **under controlled load** | drives load → shows up in the serving panels |
| **lm-eval** (quality benchmark) | accuracy on tasks (e.g. gsm8k) | **pushes** to Pushgateway → Prometheus scrapes |

```
engine/metrics ─┐
router/metrics ─┤─▶ Prometheus ─▶ Grafana
Pushgateway ────┘        ▲
GuideLLM ── load ────────┘ (seen as serving metrics)
lm-eval  ── push scores ─▶ Pushgateway
```

---

## Secure deploy pipeline (recommended)

`.github/workflows/observability-deploy.yml` deploys the monitoring stack the same
DevSecOps way as the infra/vLLM pipelines:

| Stage | Runs | Gate |
|-------|------|------|
| `validate` | **kubeconform** schema-check of the manifests | auto |
| `security-scan` | **Checkov** (k8s, SARIF → Security tab) + **gitleaks** | gitleaks blocks; findings surfaced |
| `deploy` | WIF auth → `helm upgrade --install kube-prometheus-stack` (trimmed values) + `kubectl apply` Pushgateway | **manual dispatch + approval on `production`** |

- Keyless **Workload Identity Federation**, all actions on **Node 24**.
- Uses [`kube-prom-stack-values.yaml`](kube-prom-stack-values.yaml) — trimmed for the
  free tier (no alertmanager, 2-day retention, small resource requests) and hardened
  (non-root Grafana, no hardcoded password).
- Push a change under `k8s/observability/**` → the gates run; **Run workflow → approve**
  to deploy. `uninstall` action tears it down.
- The **eval Jobs** (`guidellm-job.yaml`, `lm-eval-job.yaml`) are *measurements*, run
  on demand with `kubectl apply` — not part of the continuous deploy.

> Security note: the eval Jobs `pip install` tools at runtime as a convenience, which
> Checkov flags (unpinned image / root). For a hardened setup, bake `guidellm` and
> `lm-eval` into pinned images and reference those instead.

## Install order (manual equivalent)

### 1. Prometheus + Grafana (kube-prometheus-stack)
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prom-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```
> The Helm **release name** (`kube-prom-stack`) must match the `release:` label in
> the ServiceMonitors below, or Prometheus won't select them.

### 2. Point Prometheus at the vLLM engine + router
The production-stack repo's `observability/` install already ships ServiceMonitors
+ a Grafana dashboard for vLLM. Easiest path:
```bash
git clone https://github.com/vllm-project/production-stack.git
cd production-stack/observability && bash install.sh
```
Or write your own ServiceMonitor — first find the service names/labels/ports:
```bash
kubectl get svc -n default --show-labels        # find engine + router services
kubectl get svc vllm-router-service -n default -o yaml | grep -A3 ports
```
then create a `ServiceMonitor` (namespace `monitoring`, label `release: kube-prom-stack`)
selecting those services on the `/metrics` port.

### 3. Pushgateway (for batch eval results)
```bash
kubectl apply -f k8s/observability/pushgateway.yaml
```

### 4. Run the measurements
```bash
kubectl apply -f k8s/observability/guidellm-job.yaml   # perf benchmark (drives load)
kubectl apply -f k8s/observability/lm-eval-job.yaml     # quality benchmark (pushes scores)
kubectl logs -f job/guidellm-benchmark -n default
kubectl logs -f job/lm-eval-gsm8k -n default
```

---

## View it in Grafana
```bash
kubectl port-forward svc/kube-prom-stack-grafana 3000:80 -n monitoring
# http://localhost:3000  (default admin / prom-operator)
```
- **Serving panels** come from the production-stack dashboard (imported by its install),
  or build your own with the PromQL below.
- **Add an lm-eval panel**: new panel → query `lm_eval_score{task="gsm8k"}`.

### Useful PromQL
| Panel | Query |
|-------|-------|
| Generation tokens/s | `rate(vllm:generation_tokens_total[1m])` |
| Prompt tokens/s | `rate(vllm:prompt_tokens_total[1m])` |
| TTFT p95 (s) | `histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))` |
| E2E latency p95 (s) | `histogram_quantile(0.95, rate(vllm:e2e_request_latency_seconds_bucket[5m]))` |
| Running / waiting reqs | `vllm:num_requests_running` / `vllm:num_requests_waiting` |
| Eval accuracy | `lm_eval_score{task="gsm8k"}` |

(Exact metric names can vary by vLLM version — check `curl .../metrics` on the engine.)

---

## ⚠️ Free-tier reality

This stack is **heavy** on an 8-vCPU / $300 budget:
- kube-prometheus-stack alone wants ~1.5–2 vCPU (this is what caused the earlier
  `Insufficient cpu`). Your **app pool autoscales 1→2** to fit it, but with the
  serve node up you approach the 8-vCPU quota.
- **lm-eval on CPU is slow** — a 3B model generating gsm8k answers one at a time.
  Keep `--limit` small (10–20). Full benchmarks would take hours.
- **GuideLLM** throughput will look low — it's one CPU replica; that's expected.

**Lighter alternative:** use **GKE Managed Prometheus** for the serving metrics
(offloads scraping to Google, ~no node CPU) and run the eval Jobs one-off, reading
their console output / JSON instead of Grafana panels.

**Cost discipline:** run the eval Jobs, read the numbers, then delete them
(`kubectl delete -f ...`); scale monitoring down or uninstall it when not demoing.
