# syntax=docker/dockerfile:1
# =============================================================================
# Stage 1 — builder: compile deps, bake the embedding model + Chroma index.
# =============================================================================
FROM python@sha256:e5300dc020a26a34a19337a57602955a2510e22abeb176edd6de6cd2cc927dd4 AS builder
# ^ python:3.10-slim pinned by digest (reproducible; satisfies hadolint DL3006)

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/opt/hf

# build-essential is needed to compile some wheels; it stays in this stage only
# (never in the runtime image), so an apt version pin here is brittle for no gain.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Isolated venv so the runtime stage copies a single clean tree.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
# Patch the toolchain CVEs (wheel / setuptools-vendored jaraco.context) up front.
RUN pip install --upgrade pip setuptools wheel

WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -e .

# Bake the sentence-transformers embedding model into the image so there is NO
# HuggingFace download at runtime (works offline + under readOnlyRootFilesystem).
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"

# Build the Chroma vector store from the bundled CSVs (offline — model is cached).
RUN HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 python pipeline/build_pipeline.py

# =============================================================================
# Stage 2 — runtime: slim, non-root, no build tooling.
# =============================================================================
FROM python@sha256:e5300dc020a26a34a19337a57602955a2510e22abeb176edd6de6cd2cc927dd4

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Patch the base image's SYSTEM python tooling CVEs (done before the venv is on PATH).
RUN pip install --no-cache-dir --upgrade pip setuptools wheel

# Non-root runtime user (uid 10001 matches k8s securityContext).
RUN groupadd -g 10001 app \
    && useradd -u 10001 -g app -m -d /home/app app

# Bring in the clean venv, the baked model cache, and the app (incl. chroma_db).
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/hf /opt/hf
WORKDIR /app
COPY --from=builder /app /app

ENV PATH="/opt/venv/bin:$PATH" \
    HF_HOME=/opt/hf \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1

RUN chown -R app:app /app /opt/hf
USER app

EXPOSE 8501
CMD ["streamlit", "run", "app/app.py", "--server.port=8501", "--server.address=0.0.0.0", "--server.headless=true"]
