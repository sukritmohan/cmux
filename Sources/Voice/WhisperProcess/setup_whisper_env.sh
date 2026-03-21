#!/usr/bin/env bash
# setup_whisper_env.sh — Idempotent setup for the MLX Whisper Python environment.
#
# Creates a Python virtual environment at ~/.cmux/whisper-env/, installs
# mlx-whisper and dependencies, and downloads the whisper-large-v3-turbo-mlx model.
#
# Safe to re-run: skips steps already completed.
# Writes ~/.cmux/whisper-env/.ready on success.

set -euo pipefail

VENV_DIR="$HOME/.cmux/whisper-env"
MODEL_DIR="$HOME/.cmux/models/whisper-large-v3-turbo-mlx"
READY_MARKER="$VENV_DIR/.ready"

log() {
    echo "[setup_whisper_env] $*" >&2
}

# Ensure parent directories exist.
mkdir -p "$HOME/.cmux/models"

# Step 1: Create venv if it doesn't exist.
if [ ! -d "$VENV_DIR" ] || [ ! -f "$VENV_DIR/bin/python3" ]; then
    log "Creating Python virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
    log "Venv created."
else
    log "Venv already exists at $VENV_DIR."
fi

# Step 2: Install dependencies if mlx_whisper is not importable.
if ! "$VENV_DIR/bin/python3" -c "import mlx_whisper" 2>/dev/null; then
    log "Installing mlx-whisper, numpy, huggingface_hub..."
    "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null 2>&1
    "$VENV_DIR/bin/pip" install mlx-whisper numpy huggingface_hub
    log "Dependencies installed."
else
    log "mlx-whisper already installed."
fi

# Step 3: Download model if not present.
if [ ! -d "$MODEL_DIR" ] || [ -z "$(ls -A "$MODEL_DIR" 2>/dev/null)" ]; then
    log "Downloading whisper-large-v3-turbo-mlx model to $MODEL_DIR..."
    "$VENV_DIR/bin/python3" -c "
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/whisper-large-v3-turbo', local_dir='$MODEL_DIR')
"
    log "Model downloaded."
else
    log "Model already present at $MODEL_DIR."
fi

# Step 4: Write ready marker.
touch "$READY_MARKER"
log "Setup complete. Ready marker: $READY_MARKER"
