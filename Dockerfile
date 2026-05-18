# ============================================================
# Voicebox — Local TTS Server with Web UI (CPU)
# 3-stage build: Frontend → Python deps → Runtime
# ============================================================

ARG ROCM_RUNTIME_IMAGE=python:3.10-slim-bookworm

# === Stage 1: Build frontend ===
FROM oven/bun:1 AS frontend

WORKDIR /build

# Copy workspace config and frontend source
COPY package.json bun.lock CHANGELOG.md ./
COPY app/ ./app/
COPY web/ ./web/

# Strip workspaces not needed for web build, and fix trailing comma
RUN sed -i '/"tauri"/d; /"landing"/d' package.json && \
    sed -i -z 's/,\n  ]/\n  ]/' package.json
RUN bun install --no-save
# Build frontend (skip tsc — upstream has pre-existing type errors)
RUN cd web && bunx --bun vite build


# === Stage 2: Build Python dependencies ===
FROM python:3.11-slim AS backend-builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip

COPY backend/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
RUN pip install --no-cache-dir --prefix=/install --no-deps chatterbox-tts
RUN pip install --no-cache-dir --prefix=/install --no-deps hume-tada
RUN pip install --no-cache-dir --prefix=/install \
    git+https://github.com/QwenLM/Qwen3-TTS.git


# === Stage 3: Runtime ===
FROM python:3.11-slim

# Create non-root user for security
RUN groupadd -r voicebox && \
    useradd -r -g voicebox -m -s /bin/bash voicebox

WORKDIR /app

# Install only runtime system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libatomic1 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy installed Python packages from builder stage
COPY --from=backend-builder /install /usr/local

RUN python -c "import pedalboard"

# Copy backend application code
COPY --chown=voicebox:voicebox backend/ /app/backend/

# Copy built frontend from frontend stage
COPY --from=frontend --chown=voicebox:voicebox /build/web/dist /app/frontend/

# Create data/cache directories owned by non-root user
RUN mkdir -p /app/data/generations /app/data/profiles /app/data/cache /home/voicebox/.cache/huggingface \
    && chown -R voicebox:voicebox /app/data /home/voicebox/.cache

# Switch to non-root user
USER voicebox

# Expose the API port
EXPOSE 17493

# Health check — auto-restart if the server hangs
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
    CMD curl -f http://localhost:17493/health || exit 1

# Start the FastAPI server
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "17493"]


# === Stage 4: Build ROCm Python dependencies ===
# Use PyTorch's ROCm 5.7 wheels instead of AMD's huge rocm/pytorch image.
FROM ${ROCM_RUNTIME_IMAGE} AS rocm-builder
ARG PYTORCH_ROCM_INDEX_URL=https://download.pytorch.org/whl/rocm5.7
ARG PYTORCH_ROCM_VERSION=2.2.2
ARG TORCHVISION_ROCM_VERSION=0.17.2

ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY backend/requirements.txt .
RUN python -m venv "${VIRTUAL_ENV}" && \
    python -m pip install --no-cache-dir --upgrade pip && \
    printf "torch==%s\ntorchvision==%s\ntorchaudio==%s\n" \
        "${PYTORCH_ROCM_VERSION}" \
        "${TORCHVISION_ROCM_VERSION}" \
        "${PYTORCH_ROCM_VERSION}" > /tmp/rocm-constraints.txt && \
    python -m pip install --no-cache-dir --force-reinstall \
        "torch==${PYTORCH_ROCM_VERSION}" \
        "torchvision==${TORCHVISION_ROCM_VERSION}" \
        "torchaudio==${PYTORCH_ROCM_VERSION}" \
        --index-url "${PYTORCH_ROCM_INDEX_URL}" && \
    python -m pip install --no-cache-dir -c /tmp/rocm-constraints.txt -r requirements.txt && \
    python -m pip install --no-cache-dir --no-deps chatterbox-tts && \
    python -m pip install --no-cache-dir --no-deps hume-tada && \
    python -m pip install --no-cache-dir -c /tmp/rocm-constraints.txt \
        git+https://github.com/QwenLM/Qwen3-TTS.git


# === Stage 5: ROCm Runtime ===
FROM ${ROCM_RUNTIME_IMAGE} AS runtime-rocm

ENV PYTHONUNBUFFERED=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    HSA_OVERRIDE_GFX_VERSION=9.0.6 \
    MIOPEN_LOG_LEVEL=4

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ffmpeg \
    libatomic1 \
    libdrm-amdgpu1 \
    libdrm2 \
    libelf1 \
    libgomp1 \
    libnuma1 \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

RUN (getent group voicebox >/dev/null || groupadd -r voicebox) \
    && (getent group video >/dev/null || groupadd -r video) \
    && (getent group render >/dev/null || groupadd -r render) \
    && (id -u voicebox >/dev/null 2>&1 || useradd -r -g voicebox -G video,render -m -s /bin/bash voicebox)

COPY --from=rocm-builder /opt/venv /opt/venv

RUN python -c "import pedalboard"

COPY --chown=voicebox:voicebox backend/ /app/backend/
COPY --from=frontend --chown=voicebox:voicebox /build/web/dist /app/frontend/

RUN mkdir -p /app/data/generations /app/data/profiles /app/data/cache /home/voicebox/.cache/huggingface \
    && chown -R voicebox:voicebox /app/data /home/voicebox/.cache

USER voicebox

EXPOSE 17493

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
    CMD curl -f http://localhost:17493/health || exit 1

CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "17493"]
