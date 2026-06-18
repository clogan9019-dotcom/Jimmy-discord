#!/usr/bin/env bash
# =============================================================================
# install.sh — Discord BitNet Bot installer for Raspberry Pi 4 (64-bit OS)
# =============================================================================
# Run as a normal user with sudo privileges:
#   chmod +x install.sh && ./install.sh
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
BITNET_REPO="https://github.com/microsoft/BitNet.git"
BITNET_DIR="${SCRIPT_DIR}/bitnet_cpp_src"
# microsoft/BitNet-b1.58-2B-4T is in setup_env.py's supported list and is
# the same 2B-4T architecture as the heretic fine-tune.
MODEL_HF_REPO="microsoft/BitNet-b1.58-2B-4T"
MODEL_DIR="${SCRIPT_DIR}/models/BitNet-b1.58-2B-4T"
PYTHON_MIN_VERSION="3.11"

# ── Architecture check ────────────────────────────────────────────────────────
ARCH="$(uname -m)"
if [[ "${ARCH}" != "aarch64" ]]; then
    warn "Architecture is '${ARCH}'. This installer targets ARM64 (aarch64)."
    warn "The bot may still work, but is optimised for Raspberry Pi 4 (ARM64)."
fi

# ── Root check ────────────────────────────────────────────────────────────────
if [[ "${EUID}" -eq 0 ]]; then
    die "Do not run this script as root. Run as a regular user with sudo access."
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║       Discord BitNet Bot — Installer                ║"
echo "║       Target: Raspberry Pi 4 · ARM64 · 64-bit OS   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: System packages ───────────────────────────────────────────────────
info "Step 1/6: Updating apt and installing system dependencies…"
sudo apt-get update -qq
sudo apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    cmake \
    build-essential \
    ninja-build \
    libopenblas-dev \
    libgomp1 \
    pkg-config \
    curl \
    wget
success "System packages installed."

# ── Step 2: Python version check ─────────────────────────────────────────────
info "Step 2/6: Checking Python version…"
PYTHON_CMD=""
for cmd in python3.13 python3.12 python3.11 python3; do
    if command -v "${cmd}" &>/dev/null; then
        version="$("${cmd}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
        major="${version%%.*}"
        minor="${version#*.}"
        if (( major > 3 )) || (( major == 3 && minor >= 11 )); then
            PYTHON_CMD="${cmd}"
            break
        fi
    fi
done

if [[ -z "${PYTHON_CMD}" ]]; then
    die "Python ${PYTHON_MIN_VERSION}+ is required but not found. Install with: sudo apt-get install python3"
fi
success "Using Python: $("${PYTHON_CMD}" --version)"

# ── Step 3: Bot virtual environment ──────────────────────────────────────────
info "Step 3/6: Creating Python virtual environment at ${VENV_DIR}…"
if [[ ! -d "${VENV_DIR}" ]]; then
    "${PYTHON_CMD}" -m venv "${VENV_DIR}"
    success "Virtual environment created."
else
    info "Virtual environment already exists — skipping."
fi

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

pip install --upgrade pip setuptools wheel --quiet
info "Installing bot Python dependencies…"
pip install -r "${SCRIPT_DIR}/requirements.txt" --quiet
pip install huggingface_hub --quiet
success "Bot Python dependencies installed."

# ── Step 4: Clone BitNet repository ──────────────────────────────────────────
info "Step 4/6: Cloning BitNet repository (with submodules)…"

if [[ ! -d "${BITNET_DIR}" ]]; then
    git clone --recurse-submodules "${BITNET_REPO}" "${BITNET_DIR}"
    success "BitNet repository cloned."
else
    info "BitNet repository already exists — updating…"
    git -C "${BITNET_DIR}" pull --ff-only 2>/dev/null || true
    git -C "${BITNET_DIR}" submodule update --init --recursive
    success "BitNet repository updated."
fi

# Install BitNet runtime dependencies directly.
# BitNet's requirements.txt (and its sub-files) pin torch~=2.2.1 which has
# no wheel for Python 3.11+. We skip those files entirely and install only
# what setup_env.py actually needs, with unpinned/compatible versions.
info "Installing BitNet runtime dependencies (skipping pinned requirements files)…"
pip install \
    numpy \
    sentencepiece \
    transformers \
    gguf \
    protobuf \
    huggingface_hub \
    --quiet 2>/dev/null || \
pip install \
    numpy \
    sentencepiece \
    transformers \
    gguf \
    protobuf \
    huggingface_hub

info "Installing PyTorch CPU (latest build compatible with Python 3.13)…"
pip install torch --index-url https://download.pytorch.org/whl/cpu --quiet 2>/dev/null || \
    pip install torch --index-url https://download.pytorch.org/whl/cpu
success "BitNet dependencies installed."

# ── Step 5: Build BitNet + download model via setup_env.py ────────────────────
info "Step 5/6: Running BitNet setup_env.py…"
info "This downloads the model (~2 GB), generates kernel headers, and compiles."
info "Expect 20-40 minutes on Raspberry Pi — please be patient."
echo ""

mkdir -p "${MODEL_DIR}"
GGUF_FILE="${MODEL_DIR}/ggml-model-i2_s.gguf"

cd "${BITNET_DIR}"

if [[ -f "${GGUF_FILE}" ]] && [[ -f "${BITNET_DIR}/build/bin/llama-cli" ]]; then
    info "GGUF model and compiled binary already present — skipping."
else
    info "Running: python setup_env.py --hf-repo ${MODEL_HF_REPO} -q i2_s"
    "${VENV_DIR}/bin/python" setup_env.py \
        --hf-repo "${MODEL_HF_REPO}" \
        --model-dir "${MODEL_DIR}" \
        -q i2_s
    success "BitNet build complete."
fi

cd "${SCRIPT_DIR}"

if [[ ! -f "${GGUF_FILE}" ]]; then
    warn "Expected GGUF not found at: ${GGUF_FILE}"
    warn "Check ${MODEL_DIR} for the actual .gguf filename and update config.yaml."
else
    success "Model ready: ${GGUF_FILE}"
fi

# ── Step 6: Project directories + token reminder ──────────────────────────────
info "Step 6/6: Creating runtime directories…"
mkdir -p "${SCRIPT_DIR}/logs"
success "Directories ready."

info "Checking Discord token configuration…"
if grep -q 'token: ""' "${SCRIPT_DIR}/config.yaml" 2>/dev/null; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║              DISCORD BOT TOKEN REQUIRED             ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║                                                     ║"
    echo "║  1. Go to https://discord.com/developers/applications║"
    echo "║  2. Create a new application / bot.                 ║"
    echo "║  3. Copy your bot token.                            ║"
    echo "║  4. Set it — either:                               ║"
    echo "║       export DISCORD_TOKEN=your_token_here          ║"
    echo "║     or edit config.yaml:                            ║"
    echo "║       discord:                                      ║"
    echo '║         token: "your_token_here"                   ║'
    echo "║                                                     ║"
    echo "╚══════════════════════════════════════════════════════╝"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              Installation Complete!                 ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                     ║"
echo "║  Start the bot:                                     ║"
echo "║    source .venv/bin/activate                        ║"
echo "║    python bot.py                                    ║"
echo "║                                                     ║"
echo "║  See README.md for systemd service setup.           ║"
echo "║                                                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
success "All done. Enjoy your local AI assistant!"
