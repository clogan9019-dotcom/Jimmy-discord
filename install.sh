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
BUILD_MODEL_REPO="microsoft/BitNet-b1.58-2B-4T"
BUILD_MODEL_DIR="${SCRIPT_DIR}/models/BitNet-b1.58-2B-4T"
HERETIC_REPO="askalgore/bitnet-b1.58-2B-4T-heretic"
HERETIC_DIR="${SCRIPT_DIR}/models/heretic"
PYTHON_MIN_VERSION="3.11"

# Shorthand — always use these instead of bare pip/python to avoid
# accidentally hitting the system interpreter (PEP 668 blocks that).
VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"

# ── Architecture check ────────────────────────────────────────────────────────
ARCH="$(uname -m)"
if [[ "${ARCH}" != "aarch64" ]]; then
    warn "Architecture is '${ARCH}'. This installer targets ARM64 (aarch64)."
    warn "The bot may still work, but is optimised for Raspberry Pi 4 (ARM64)."
fi

# ── Space-in-path check ───────────────────────────────────────────────────────
if [[ "${SCRIPT_DIR}" == *" "* ]]; then
    warn "Your install path contains a space:"
    warn "  ${SCRIPT_DIR}"
    warn "This can cause huggingface-cli to fail inside setup_env.py."
    warn "To avoid issues, move the project to a path without spaces, e.g.:"
    warn "  mv \"${SCRIPT_DIR}\" \"\${HOME}/Jimmy-discord\""
    warn "Continuing anyway — using Python snapshot_download as a workaround."
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

# If the venv exists but its Python binary is missing or broken, recreate it.
if [[ -d "${VENV_DIR}" ]]; then
    if [[ ! -x "${VENV_PYTHON}" ]] || ! "${VENV_PYTHON}" -c "import sys" &>/dev/null; then
        warn "Existing venv is broken — recreating…"
        rm -rf "${VENV_DIR}"
    else
        info "Virtual environment already exists and is healthy — skipping creation."
    fi
fi

if [[ ! -d "${VENV_DIR}" ]]; then
    "${PYTHON_CMD}" -m venv "${VENV_DIR}"
    success "Virtual environment created."
fi

# Always use explicit venv paths — never rely on 'source activate' in scripts.
# Debian/Raspberry Pi OS (PEP 668) blocks system-pip installs; using the venv
# pip directly is the only safe approach.
"${VENV_PIP}" install --upgrade pip "setuptools<82" wheel --quiet
info "Installing bot Python dependencies…"
"${VENV_PIP}" install -r "${SCRIPT_DIR}/requirements.txt" --quiet
"${VENV_PIP}" install huggingface_hub --quiet
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
# BitNet's requirements.txt pins torch~=2.2.1 which has no wheel for Python 3.11+.
# We skip those files and install only what setup_env.py actually needs.
info "Installing BitNet runtime dependencies (skipping pinned requirements files)…"
"${VENV_PIP}" install \
    numpy \
    sentencepiece \
    transformers \
    gguf \
    protobuf \
    huggingface_hub \
    --quiet 2>/dev/null || \
"${VENV_PIP}" install \
    numpy \
    sentencepiece \
    transformers \
    gguf \
    protobuf \
    huggingface_hub

info "Installing PyTorch CPU…"
"${VENV_PIP}" install torch --index-url https://download.pytorch.org/whl/cpu --quiet 2>/dev/null || \
    "${VENV_PIP}" install torch --index-url https://download.pytorch.org/whl/cpu
success "BitNet dependencies installed."

# ── Step 5: Build bitnet.cpp, then quantize the heretic model ─────────────────
info "Step 5/6: Building bitnet.cpp and setting up the heretic model…"
info "Expect 20-40 minutes total on Raspberry Pi — please be patient."
echo ""

HERETIC_GGUF="${HERETIC_DIR}/ggml-model-i2_s.gguf"
LLAMA_QUANTIZE="${BITNET_DIR}/build/bin/llama-quantize"
CONVERT_SCRIPT="${BITNET_DIR}/3rdparty/llama.cpp/convert_hf_to_gguf.py"

# ── 5a: Build bitnet.cpp using the official Microsoft model ───────────────────
mkdir -p "${BUILD_MODEL_DIR}"
cd "${BITNET_DIR}"

if [[ -f "${LLAMA_QUANTIZE}" ]]; then
    info "BitNet binary already compiled — skipping build step."
else
    # Pre-download the Microsoft model using Python's snapshot_download.
    # This bypasses setup_env.py's internal huggingface-cli call, which fails
    # when the install path contains spaces.
    # setup_env.py appends the model name to --model-dir, so the effective
    # download target is BUILD_MODEL_DIR/<model_name>.
    BUILD_MODEL_NAME="$(basename "${BUILD_MODEL_REPO}")"
    BUILD_MODEL_DOWNLOAD_DIR="${BUILD_MODEL_DIR}/${BUILD_MODEL_NAME}"
    mkdir -p "${BUILD_MODEL_DOWNLOAD_DIR}"

    if [[ ! -f "${BUILD_MODEL_DOWNLOAD_DIR}/config.json" ]]; then
        info "Phase 1/3: Downloading ${BUILD_MODEL_REPO} model…"
        info "(~2 GB — may take 10-20 min depending on your connection)"
        "${VENV_PYTHON}" - <<PYEOF
import sys
from huggingface_hub import snapshot_download
print("Downloading ${BUILD_MODEL_REPO} ...", flush=True)
try:
    snapshot_download(repo_id="${BUILD_MODEL_REPO}", local_dir="${BUILD_MODEL_DOWNLOAD_DIR}")
    print("Download complete.", flush=True)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        success "Microsoft model downloaded."
    else
        info "Microsoft model already present — skipping download."
    fi

    info "Phase 1/3: Building bitnet.cpp via setup_env.py (using ${BUILD_MODEL_REPO})…"
    info "(Compiling only — model already downloaded — takes 15-30 min)"
    "${VENV_PYTHON}" setup_env.py \
        --hf-repo "${BUILD_MODEL_REPO}" \
        --model-dir "${BUILD_MODEL_DIR}" \
        -q i2_s
    success "BitNet binary compiled."
fi

cd "${SCRIPT_DIR}"

# ── 5b: Download the heretic model ────────────────────────────────────────────
mkdir -p "${HERETIC_DIR}"

if [[ -f "${HERETIC_GGUF}" ]]; then
    info "Heretic GGUF already present — skipping download and conversion."
else
    if [[ ! -f "${HERETIC_DIR}/config.json" ]]; then
        info "Phase 2/3: Downloading heretic model (${HERETIC_REPO})…"
        info "(~2 GB — may take 10-20 min depending on your connection)"
        "${VENV_PYTHON}" - <<PYEOF
import sys
from huggingface_hub import snapshot_download
print(f"Downloading ${HERETIC_REPO} ...", flush=True)
try:
    snapshot_download(repo_id="${HERETIC_REPO}", local_dir="${HERETIC_DIR}")
    print("Download complete.", flush=True)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        success "Heretic model downloaded."
    else
        info "Heretic model files already present — skipping download."
    fi

    # ── 5c: Convert heretic to GGUF and quantize to i2_s ─────────────────────
    info "Phase 3/3: Converting heretic model to GGUF and quantizing to i2_s…"
    info "(This may take 10-20 min on Raspberry Pi)"

    HERETIC_F16="${HERETIC_DIR}/model-f16.gguf"

    if [[ ! -f "${HERETIC_F16}" ]]; then
        info "Converting to F16 GGUF…"
        "${VENV_PYTHON}" "${CONVERT_SCRIPT}" \
            "${HERETIC_DIR}" \
            --outfile "${HERETIC_F16}" \
            --outtype f16
        success "F16 GGUF created."
    fi

    info "Quantizing to i2_s…"
    "${LLAMA_QUANTIZE}" "${HERETIC_F16}" "${HERETIC_GGUF}" i2_s
    success "Heretic model quantized."

    info "Removing intermediate F16 file to save disk space…"
    rm -f "${HERETIC_F16}"
fi

if [[ ! -f "${HERETIC_GGUF}" ]]; then
    warn "Heretic GGUF not found at: ${HERETIC_GGUF}"
    warn "Check ${HERETIC_DIR} and update config.yaml if the filename differs."
else
    success "Heretic model ready: ${HERETIC_GGUF}"
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
