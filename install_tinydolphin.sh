#!/usr/bin/env bash
# =============================================================================
# install_tinydolphin.sh - Fast TinyDolphin/TinyLlama GGUF setup for Raspberry Pi
# =============================================================================
# This switches the bot away from the slow BitNet Heretic model and uses a small
# ready-made TinyDolphin 1.1B Q4_K_M GGUF model instead.
# =============================================================================

set -euo pipefail

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"
BITNET_REPO="https://github.com/microsoft/BitNet.git"
BITNET_DIR="${SCRIPT_DIR}/bitnet_cpp_src"
MODEL_DIR="${SCRIPT_DIR}/models/tinydolphin"
MODEL_FILE="${MODEL_DIR}/tinydolphin-2.8.1-1.1b-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/v8karlo/UNCENSORED-TinyDolphin-2.8.1-1.1b-Q4_K_M-GGUF/resolve/main/tinydolphin-2.8.1-1.1b-q4_k_m.gguf?download=true"

if [[ "${EUID}" -eq 0 ]]; then
    die "Do not run this script as root. Run as your normal user."
fi

cat <<'BANNER'
===========================================================
 Jimmy Discord Bot - TinyDolphin fast GGUF installer
 Model: TinyDolphin 2.8.1 1.1B Q4_K_M GGUF
===========================================================
BANNER

info "Step 1/5: Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    cmake \
    build-essential \
    clang \
    ninja-build \
    curl \
    wget
success "System packages ready."

info "Step 2/5: Preparing Python virtual environment..."
if [[ ! -x "${VENV_PYTHON}" ]]; then
    python3 -m venv "${VENV_DIR}"
fi
"${VENV_PIP}" install --upgrade pip "setuptools<82" wheel --quiet
"${VENV_PIP}" install -r "${SCRIPT_DIR}/requirements.txt" --quiet
success "Python environment ready."

info "Step 3/5: Ensuring llama-cli exists..."
if [[ ! -d "${BITNET_DIR}" ]]; then
    git clone --recurse-submodules "${BITNET_REPO}" "${BITNET_DIR}"
else
    git -C "${BITNET_DIR}" pull --ff-only 2>/dev/null || true
    git -C "${BITNET_DIR}" submodule update --init --recursive
fi

cd "${BITNET_DIR}"
if [[ ! -x "build/bin/llama-cli" || ! -f "build/.jimmy-pi4-safe" ]]; then
    if [[ -x "build/bin/llama-cli" && ! -f "build/.jimmy-pi4-safe" ]]; then
        warn "Existing llama-cli build may contain Pi-4-incompatible dotprod instructions; rebuilding."
    fi
    info "Building llama-cli for this Raspberry Pi (no model download)..."
    "${VENV_PYTHON}" utils/codegen_tl1.py \
        --model bitnet_b1_58-3B \
        --BM 160,320,320 \
        --BK 64,128,64 \
        --bm 32,64,32

    info "Patching llama.cpp ARM build flags for Raspberry Pi 4 compatibility (disable dotprod)..."
    python3 - <<'PYEOF'
from pathlib import Path
p = Path("3rdparty/llama.cpp/ggml/src/CMakeLists.txt")
text = p.read_text()
text = text.replace(
    "add_compile_definitions(__ARM_FEATURE_DOTPROD)",
    "# Jimmy-discord: disabled for Raspberry Pi 4 compatibility\n            # add_compile_definitions(__ARM_FEATURE_DOTPROD)",
)
text = text.replace(
    "list(APPEND ARCH_FLAGS -march=armv8.2-a+dotprod)",
    "# Jimmy-discord: disabled for Raspberry Pi 4 compatibility\n                # list(APPEND ARCH_FLAGS -march=armv8.2-a+dotprod)",
)
p.write_text(text)
PYEOF

    rm -rf build
    cmake -B build \
        -G Ninja \
        -DBITNET_ARM_TL1=OFF \
        -DGGML_NATIVE=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++
    cmake --build build --config Release
    touch build/.jimmy-pi4-safe
fi
cd "${SCRIPT_DIR}"
[[ -x "${BITNET_DIR}/build/bin/llama-cli" ]] || die "llama-cli was not built."
success "llama-cli ready."

info "Step 4/5: Downloading TinyDolphin GGUF..."
mkdir -p "${MODEL_DIR}"
if [[ -f "${MODEL_FILE}" ]]; then
    size="$(stat -c%s "${MODEL_FILE}" 2>/dev/null || echo 0)"
    if (( size < 100000000 )); then
        warn "Existing TinyDolphin file is too small; redownloading."
        rm -f "${MODEL_FILE}"
    fi
fi

if [[ ! -f "${MODEL_FILE}" ]]; then
    tmp="${MODEL_FILE}.part"
    header_args=()
    if [[ -n "${HF_TOKEN:-}" ]]; then
        header_args=(-H "Authorization: Bearer ${HF_TOKEN}")
    fi
    curl -L --fail --retry 10 --retry-delay 5 --continue-at - \
        "${header_args[@]}" \
        -o "${tmp}" \
        "${MODEL_URL}"
    mv "${tmp}" "${MODEL_FILE}"
fi

size="$(stat -c%s "${MODEL_FILE}" 2>/dev/null || echo 0)"
if (( size < 100000000 )); then
    die "Downloaded TinyDolphin GGUF is too small: ${MODEL_FILE}"
fi
success "TinyDolphin model ready: ${MODEL_FILE}"

info "Step 5/5: Updating config.yaml for TinyDolphin..."
"${VENV_PYTHON}" - <<'PYEOF'
from pathlib import Path
path = Path("config.yaml")
text = path.read_text(encoding="utf-8")
replacements = {
    "model": '  model: "./models/tinydolphin/tinydolphin-2.8.1-1.1b-q4_k_m.gguf"',
    "context": "  context: 2048",
    "max_tokens": "  max_tokens: 512",
    "temperature": "  temperature: 0.7",
    "top_p": "  top_p: 0.9",
    "top_k": "  top_k: 40",
    "repeat_penalty": "  repeat_penalty: 1.1",
}
lines = text.splitlines()
in_bitnet = False
seen = set()
out = []
for line in lines:
    stripped = line.strip()
    if line.startswith("bitnet:"):
        in_bitnet = True
        out.append(line)
        continue
    if in_bitnet and line and not line.startswith(" ") and not line.startswith("#"):
        for key, value in replacements.items():
            if key not in seen:
                out.append(value)
        in_bitnet = False
    if in_bitnet:
        key = stripped.split(":", 1)[0] if ":" in stripped else None
        if key in replacements:
            out.append(replacements[key])
            seen.add(key)
            continue
    out.append(line)
if in_bitnet:
    for key, value in replacements.items():
        if key not in seen:
            out.append(value)
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PYEOF

if [[ -f "memory.db" ]]; then
    backup="memory.db.backup.$(date +%Y%m%d-%H%M%S)"
    warn "Backing up old conversation memory to ${backup} because it may contain old BitNet error prompts."
    mv memory.db "${backup}"
fi

success "TinyDolphin setup complete."
echo ""
info "Start the bot with:"
info "  cd ${SCRIPT_DIR}"
info "  source .venv/bin/activate"
info "  python bot.py"
