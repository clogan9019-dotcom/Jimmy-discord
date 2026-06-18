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
NC='\033[0m'  # No Colour

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
BITNET_EXECUTABLE="${SCRIPT_DIR}/bitnet"
MODEL_DIR="${SCRIPT_DIR}/models/heretic"
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
info "Step 1/7: Updating apt and installing system dependencies…"
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
    wget \
    2>/dev/null
success "System packages installed."

# ── Step 2: Python version check ─────────────────────────────────────────────
info "Step 2/7: Checking Python version…"
PYTHON_CMD=""
for cmd in python3.12 python3.11 python3; do
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
    die "Python ${PYTHON_MIN_VERSION}+ is required but was not found. " \
        "Install it with: sudo apt-get install python3.11"
fi
success "Using Python: $("${PYTHON_CMD}" --version)"

# ── Step 3: Virtual environment ───────────────────────────────────────────────
info "Step 3/7: Creating Python virtual environment at ${VENV_DIR}…"
if [[ ! -d "${VENV_DIR}" ]]; then
    "${PYTHON_CMD}" -m venv "${VENV_DIR}"
    success "Virtual environment created."
else
    info "Virtual environment already exists — skipping creation."
fi

# Activate venv for the rest of this script
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

pip install --upgrade pip setuptools wheel --quiet
info "Installing Python dependencies from requirements.txt…"
pip install -r "${SCRIPT_DIR}/requirements.txt" --quiet
success "Python dependencies installed."

# ── Step 4: Build bitnet.cpp ──────────────────────────────────────────────────
info "Step 4/7: Cloning and building bitnet.cpp…"

if [[ ! -d "${BITNET_DIR}" ]]; then
    info "Cloning BitNet repository with submodules (llama.cpp)…"
    git clone --recurse-submodules "${BITNET_REPO}" "${BITNET_DIR}"
else
    info "BitNet repository already cloned — updating submodules…"
    git -C "${BITNET_DIR}" pull --ff-only 2>/dev/null || true
    git -C "${BITNET_DIR}" submodule update --init --recursive
fi

BUILD_DIR="${BITNET_DIR}/build"
mkdir -p "${BUILD_DIR}"

info "Configuring build with CMake (ARM64 optimisations)…"
cmake \
    -S "${BITNET_DIR}" \
    -B "${BUILD_DIR}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBITNET_ARM_TL1=ON \
    -DCMAKE_C_FLAGS="-march=armv8-a+simd -O3" \
    -DCMAKE_CXX_FLAGS="-march=armv8-a+simd -O3"

info "Building bitnet.cpp with $(nproc) thread(s) — this takes several minutes…"
cmake --build "${BUILD_DIR}" --config Release -j "$(nproc)"

# Locate the built executable
BUILT_EXEC=""
for candidate in \
    "${BUILD_DIR}/bin/run_inference" \
    "${BUILD_DIR}/run_inference" \
    "${BUILD_DIR}/bin/bitnet" \
    "${BUILD_DIR}/bitnet"; do
    if [[ -x "${candidate}" ]]; then
        BUILT_EXEC="${candidate}"
        break
    fi
done

if [[ -z "${BUILT_EXEC}" ]]; then
    warn "Could not locate the built executable automatically."
    warn "Check ${BUILD_DIR} and update config.yaml with the correct path."
else
    cp "${BUILT_EXEC}" "${BITNET_EXECUTABLE}"
    chmod +x "${BITNET_EXECUTABLE}"
    success "BitNet executable copied to ${BITNET_EXECUTABLE}."
fi

# ── Step 5: Model download ────────────────────────────────────────────────────
info "Step 5/7: Setting up model directory…"
mkdir -p "${MODEL_DIR}"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                  MODEL DOWNLOAD INSTRUCTIONS                   ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║                                                                 ║"
echo "║  Model: askalgore/bitnet-b1.58-2B-4T-heretic                   ║"
echo "║                                                                 ║"
echo "║  Due to licensing, the model cannot be downloaded              ║"
echo "║  automatically. Please follow these steps:                     ║"
echo "║                                                                 ║"
echo "║  1. Visit:                                                      ║"
echo "║     https://huggingface.co/askalgore/bitnet-b1.58-2B-4T-heretic║"
echo "║                                                                 ║"
echo "║  2. Log in / create a Hugging Face account if required.        ║"
echo "║                                                                 ║"
echo "║  3. Download the model files and place them in:                ║"
echo "║     ${MODEL_DIR}"
echo "║                                                                 ║"
echo "║  4. Or use huggingface-cli:                                     ║"
echo "║     pip install huggingface_hub                                 ║"
echo "║     huggingface-cli download \\                                  ║"
echo "║       askalgore/bitnet-b1.58-2B-4T-heretic \\                   ║"
echo "║       --local-dir ${MODEL_DIR}"
echo "║                                                                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Attempt automatic download via huggingface_hub if available
if "${VENV_DIR}/bin/python" -c "import huggingface_hub" 2>/dev/null; then
    echo -n "Attempt automatic model download via huggingface_hub? [y/N] "
    read -r answer
    if [[ "${answer,,}" == "y" ]]; then
        info "Downloading model — this may take a long time on Raspberry Pi…"
        "${VENV_DIR}/bin/python" - <<'PYEOF'
from huggingface_hub import snapshot_download
import os, sys

model_id = "askalgore/bitnet-b1.58-2B-4T-heretic"
local_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models", "heretic")

print(f"Downloading {model_id} to {local_dir} …")
try:
    snapshot_download(repo_id=model_id, local_dir=local_dir)
    print("Model downloaded successfully.")
except Exception as e:
    print(f"Download failed: {e}", file=sys.stderr)
    print("Please download manually as described above.", file=sys.stderr)
    sys.exit(1)
PYEOF
    fi
else
    info "huggingface_hub not installed — skipping automatic download."
    info "Install it with: pip install huggingface_hub"
fi

# ── Step 6: Create project directories ───────────────────────────────────────
info "Step 6/7: Creating required directories…"
mkdir -p \
    "${SCRIPT_DIR}/logs" \
    "${SCRIPT_DIR}/models"
success "Directories ready."

# ── Step 7: Discord token setup ───────────────────────────────────────────────
info "Step 7/7: Discord bot token configuration…"
if grep -q '^  token: ""' "${SCRIPT_DIR}/config.yaml" 2>/dev/null; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║              DISCORD BOT TOKEN REQUIRED             ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║                                                     ║"
    echo "║  1. Go to https://discord.com/developers/applications║"
    echo "║  2. Create a new application / bot.                 ║"
    echo "║  3. Copy your bot token.                            ║"
    echo "║  4. Either:                                         ║"
    echo "║     a) Export it:                                   ║"
    echo "║        export DISCORD_TOKEN=your_token_here         ║"
    echo "║     b) Or edit config.yaml and set:                 ║"
    echo "║        discord:                                     ║"
    echo "║          token: \"your_token_here\"                  ║"
    echo "║                                                     ║"
    echo "╚══════════════════════════════════════════════════════╝"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              Installation Complete!                 ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                     ║"
echo "║  To start the bot:                                  ║"
echo "║                                                     ║"
echo "║    source .venv/bin/activate                        ║"
echo "║    python bot.py                                    ║"
echo "║                                                     ║"
echo "║  Or with a custom config:                           ║"
echo "║    python bot.py --config /path/to/config.yaml      ║"
echo "║                                                     ║"
echo "║  To run on startup (systemd):                       ║"
echo "║    See README.md for the systemd service example.   ║"
echo "║                                                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

success "All done. Enjoy your local AI assistant!"
