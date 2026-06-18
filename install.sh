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
    if [[ ! -x "${VENV_PYTHON}" ]] || ! "${VENV_PYTHON}" -c "import sys" &>/dev/null || ! "${VENV_PIP}" --version &>/dev/null; then
        warn "Existing venv is broken or was moved/renamed — recreating…"
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

info "Installing local gguf-py from BitNet submodule (has TL1/TL2 BitNet quant types)…"
"${VENV_PIP}" install "${BITNET_DIR}/3rdparty/llama.cpp/gguf-py" --quiet 2>/dev/null ||     "${VENV_PIP}" install "${BITNET_DIR}/3rdparty/llama.cpp/gguf-py"
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
CONVERT_SCRIPT="${BITNET_DIR}/utils/convert-hf-to-gguf-bitnet.py"

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
    NEED_HERETIC_DOWNLOAD=0
    if [[ ! -f "${HERETIC_DIR}/config.json" ]]; then
        NEED_HERETIC_DOWNLOAD=1
    elif [[ ! -f "${HERETIC_DIR}/model.safetensors" ]]; then
        warn "Heretic config exists but model.safetensors is missing. The previous download is incomplete."
        NEED_HERETIC_DOWNLOAD=1
    else
        heretic_weight_size="$(stat -c%s "${HERETIC_DIR}/model.safetensors" 2>/dev/null || echo 0)"
        if (( heretic_weight_size < 1073741824 )); then
            warn "Heretic model.safetensors is smaller than 1 GB. It is probably a partial/LFS-pointer file — deleting it."
            rm -f "${HERETIC_DIR}/model.safetensors"
            NEED_HERETIC_DOWNLOAD=1
        fi
    fi

    if (( NEED_HERETIC_DOWNLOAD )); then
        info "Phase 2/3: Downloading heretic model (${HERETIC_REPO})…"
        info "(~5 GB — may take a while depending on your connection)"
        "${VENV_PYTHON}" - <<PYEOF
import os
import sys
# Make large HF downloads more reliable. These must be set before importing huggingface_hub.
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "60")
os.environ.setdefault("HF_XET_HIGH_PERFORMANCE", "1")
from huggingface_hub import snapshot_download
print(f"Downloading ${HERETIC_REPO} ...", flush=True)
try:
    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    if token:
        print("Using HF_TOKEN for authenticated Hugging Face download.", flush=True)
    else:
        print("WARNING: HF_TOKEN is not set; download may be slower/rate-limited.", flush=True)
    snapshot_download(repo_id="${HERETIC_REPO}", local_dir="${HERETIC_DIR}", token=token, max_workers=1)
    print("Download complete.", flush=True)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        success "Heretic model downloaded."
    else
        info "Heretic model files already present — skipping download."
    fi

    if [[ ! -f "${HERETIC_DIR}/model.safetensors" ]] || (( $(stat -c%s "${HERETIC_DIR}/model.safetensors" 2>/dev/null || echo 0) < 1073741824 )); then
        die "Heretic weights are still missing or too small: ${HERETIC_DIR}/model.safetensors. Delete models/heretic and rerun install.sh."
    fi

    # ── 5c: Convert heretic to GGUF and quantize to i2_s ─────────────────────
    info "Phase 3/3: Converting heretic model to GGUF and quantizing to i2_s…"
    info "(This may take 10-20 min on Raspberry Pi)"

    HERETIC_F16="${HERETIC_DIR}/model-f16.gguf"

    if [[ -f "${HERETIC_F16}" && ! -f "${HERETIC_GGUF}" ]]; then
        f16_size="$(stat -c%s "${HERETIC_F16}" 2>/dev/null || echo 0)"
        if (( f16_size < 1073741824 )); then
            warn "Existing F16 GGUF is smaller than 1 GB, so it is probably a partial failed conversion — removing it."
            rm -f "${HERETIC_F16}"
        else
            info "Found existing F16 GGUF intermediate — using it for i2_s quantization."
            info "If this file is from a failed/partial conversion, delete it and rerun: rm -f \"${HERETIC_F16}\""
        fi
    fi

    if [[ ! -f "${HERETIC_F16}" ]]; then
        # The heretic model uses a LLaMA-3 tiktoken tokenizer (tokenizer.json only,
        # no tokenizer.model). LLaMA-3 uses BPE (tiktoken), so patch the converter
        # to call _set_vocab_gpt2() (BpeVocab). Use -E extended regex so the sed is
        # idempotent: it replaces sentencepiece OR llama_hf, whichever is on disk.
        info "Patching BitNet converter to use LLaMA-3 BPE tokenizer (gpt2/BpeVocab) for heretic model…"
        sed -i -E 's/self\._set_vocab_(sentencepiece|llama_hf)\(\)/self._set_vocab_gpt2()/g' \
            "${BITNET_DIR}/utils/convert-hf-to-gguf-bitnet.py"

        info "Patching heretic config.json architecture name (BitNetForCausalLM → BitnetForCausalLM)…"
        sed -i 's/BitNetForCausalLM/BitnetForCausalLM/g' "${HERETIC_DIR}/config.json"

        info "Patching BitNet converter to handle offline BitNet weight_scale tensors…"
        "${VENV_PYTHON}" - "${CONVERT_SCRIPT}" <<'PYEOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

# Newer tokenizer/transformers combinations produce this checksum for the
# heretic model, but it is still the LLaMA-3 BPE pre-tokenizer.
if "f15ce481ca8fccf8c06fd3d936c1c7f79b64c61a92f6cf846fcf725ff98f4461" not in text:
    text = text.replace(
        "        res = None\n\n        # NOTE:",
        "        res = None\n\n"
        "        if chkhsh == \"f15ce481ca8fccf8c06fd3d936c1c7f79b64c61a92f6cf846fcf725ff98f4461\":\n"
        "            # ref: askalgore/bitnet-b1.58-2B-4T-heretic (LLaMA-3 BPE)\n"
        "            res = \"llama-bpe\"\n\n"
        "        # NOTE:",
        1,
    )

# If the exact BPE pre-tokenizer checksum changes across tokenizer/transformers
# versions, keep going for this known heretic LLaMA-3 tokenizer instead of
# aborting. The converter only needs tokenizer.ggml.pre="llama-bpe" here.
if "defaulting tokenizer.ggml.pre to llama-bpe for heretic model" not in text:
    text = text.replace(
        '            raise NotImplementedError("BPE pre-tokenizer was not recognized - update get_vocab_base_pre()")',
        '            logger.warning("BPE pre-tokenizer was not recognized; defaulting tokenizer.ggml.pre to llama-bpe for heretic model")\n'
        '            res = "llama-bpe"',
        1,
    )

# Microsoft BitNet's converter currently maps regular weight/bias tensors, but
# offline AutoBitLinear checkpoints also contain sibling `.weight_scale` tensors.
# The heretic checkpoint stores unpacked ternary BF16 weights plus those scales;
# upstream BitNet checkpoints may store packed U8 weights plus those scales. GGUF
# has no separate mapping for `.weight_scale`, so consume the scales here and
# skip the scale tensors during conversion. The patch is idempotent.
if "self._bitnet_skip_weight_quant" not in text:
    old_modify = '''    def modify_tensors(self, data_torch: Tensor, name: str, bid: int | None) -> Iterable[tuple[str, Tensor]]:
        # quant weight to i2 (in fp16)
        if name.endswith(("q_proj.weight", "k_proj.weight", "v_proj.weight", 
                          "down_proj.weight", "up_proj.weight", "gate_proj.weight",
                          "o_proj.weight")):
            data_torch = self.weight_quant(data_torch)

        return [(self.map_tensor_name(name), data_torch)]
'''
    new_modify = '''    def modify_tensors(self, data_torch: Tensor, name: str, bid: int | None) -> Iterable[tuple[str, Tensor]]:
        # Some BitNet/AutoBitLinear checkpoints store pre-quantized ternary
        # weights plus a sibling .weight_scale tensor. write_tensors() consumes
        # those scales before tensors get here, so do not re-quantize them.
        if name in getattr(self, "_bitnet_skip_weight_quant", set()):
            return [(self.map_tensor_name(name), data_torch)]

        # quant weight to i2 (in fp16)
        if name.endswith(("q_proj.weight", "k_proj.weight", "v_proj.weight", 
                          "down_proj.weight", "up_proj.weight", "gate_proj.weight",
                          "o_proj.weight")):
            data_torch = self.weight_quant(data_torch)

        return [(self.map_tensor_name(name), data_torch)]
'''
    if old_modify not in text:
        raise SystemExit("Could not patch BitNet converter modify_tensors block; upstream changed.")
    text = text.replace(old_modify, new_modify, 1)

    old_write = '''    def write_tensors(self):
        max_name_len = max(len(s) for _, s in self.tensor_map.mapping.values()) + len(".weight,")

        for name, data_torch in self.get_tensors():
            # we don't need these
            if name.endswith((".attention.masked_bias", ".attention.bias", ".rotary_emb.inv_freq")):
                continue

            old_dtype = data_torch.dtype

            # convert any unsupported data types to float32
'''
    new_write = '''    def write_tensors(self):
        max_name_len = max(len(s) for _, s in self.tensor_map.mapping.values()) + len(".weight,")

        scale_map = {}
        for name, data_torch in self.get_tensors():
            if name.endswith("weight_scale"):
                scale_map[name.replace(".weight_scale", "")] = data_torch.to(torch.float32)
        self._bitnet_skip_weight_quant = set()

        for name, data_torch in self.get_tensors():
            if name.endswith("weight_scale"):
                continue

            # Offline BitNet/AutoBitLinear checkpoints store a ternary weight
            # tensor plus a sibling scalar .weight_scale. GGUF expects the
            # de-scaled float weights and has no tensor mapping for weight_scale.
            if name.endswith(".weight"):
                scale = scale_map.get(name[:-len(".weight")])
                if scale is not None:
                    if data_torch.dtype == torch.uint8:
                        origin_shape = data_torch.shape
                        shift = torch.tensor([0, 2, 4, 6], dtype=torch.uint8).reshape((4, *(1 for _ in range(len(origin_shape)))))
                        data_torch = data_torch.unsqueeze(0).expand((4, *origin_shape)) >> shift
                        data_torch = data_torch & 3
                        data_torch = (data_torch.float() - 1).reshape((origin_shape[0] * 4, *origin_shape[1:]))
                    else:
                        data_torch = data_torch.to(torch.float32)
                    data_torch = data_torch / scale.float()
                    self._bitnet_skip_weight_quant.add(name)

            # we don't need these
            if name.endswith((".attention.masked_bias", ".attention.bias", ".rotary_emb.inv_freq")):
                continue

            old_dtype = data_torch.dtype

            # convert any unsupported data types to float32
'''
    if old_write not in text:
        raise SystemExit("Could not patch BitNet converter write_tensors block; upstream changed.")
    text = text.replace(old_write, new_write, 1)
    path.write_text(text)

# Always write the file because tokenizer patches above may be applied even when
# the weight_scale patch is already present from a previous installer run.
path.write_text(text)
PYEOF
        info "Converting to F16 GGUF…"
        "${VENV_PYTHON}" "${CONVERT_SCRIPT}" \
            "${HERETIC_DIR}" \
            --outfile "${HERETIC_F16}" \
            --outtype f16
        if [[ ! -f "${HERETIC_F16}" ]] || (( $(stat -c%s "${HERETIC_F16}" 2>/dev/null || echo 0) < 1073741824 )); then
            rm -f "${HERETIC_F16}"
            die "F16 GGUF conversion produced a metadata-only/too-small file. The Heretic weights were not loaded correctly. Delete models/heretic and rerun install.sh."
        fi
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


# ── Step 7: Install systemd service (optional) ────────────────────────────────
info "Step 7/7: Setting up systemd service…"
SERVICE_NAME="jimmy-discord"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CURRENT_USER="$(whoami)"

# Write a populated service file into the repo for reference
cat > "${SCRIPT_DIR}/jimmy-discord.service" <<SERVICE
[Unit]
Description=Jimmy Discord BitNet AI Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CURRENT_USER}
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/.venv/bin/python bot.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=jimmy-discord

[Install]
WantedBy=multi-user.target
SERVICE

success "Service file written to ${SCRIPT_DIR}/jimmy-discord.service"

echo ""
read -r -p "$(echo -e "${BLUE}[INFO]${NC}  Install and enable the systemd service now? [y/N] ")" INSTALL_SERVICE
if [[ "${INSTALL_SERVICE,,}" == "y" ]]; then
    sudo cp "${SCRIPT_DIR}/jimmy-discord.service" "${SERVICE_FILE}"
    sudo systemctl daemon-reload
    sudo systemctl enable "${SERVICE_NAME}"
    sudo systemctl start  "${SERVICE_NAME}"
    success "Service installed and started."
    info  "Useful commands:"
    info  "  sudo systemctl status ${SERVICE_NAME}"
    info  "  sudo journalctl -u ${SERVICE_NAME} -f"
    info  "  sudo systemctl restart ${SERVICE_NAME}"
else
    info "Skipped. To install manually later:"
    info "  sudo cp ${SCRIPT_DIR}/jimmy-discord.service ${SERVICE_FILE}"
    info "  sudo systemctl daemon-reload"
    info "  sudo systemctl enable --now ${SERVICE_NAME}"
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
