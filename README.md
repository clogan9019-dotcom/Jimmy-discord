# Jimmy Discord AI Bot

A local Discord AI bot for Raspberry Pi 4.

The current recommended setup uses a fast **TinyDolphin / TinyLlama 1.1B GGUF** model on-device through `llama-cli`. The older BitNet Heretic setup is still supported, but it is slower and harder to build on a Raspberry Pi.

No OpenAI, Anthropic, Groq, Ollama cloud, or other external AI API is required for normal chat inference. The model runs on your hardware.

---

## Current recommended model

Recommended fast model:

```text
v8karlo/UNCENSORED-TinyDolphin-2.8.1-1.1b-Q4_K_M-GGUF
```

Direct GGUF file:

```text
https://huggingface.co/v8karlo/UNCENSORED-TinyDolphin-2.8.1-1.1b-Q4_K_M-GGUF/resolve/main/tinydolphin-2.8.1-1.1b-q4_k_m.gguf?download=true
```

Expected local path on the Pi:

```text
~/Jimmy-2/Jimmy-discord/models/tinydolphin/tinydolphin-2.8.1-1.1b-q4_k_m.gguf
```

Approximate size:

```text
~638 MB
```

---

## Features

- Local on-device AI replies on Raspberry Pi 4
- `/chat` slash command
- Replies to `@Jimmy ...` mentions
- Replies when you reply to one of the bot's messages
- Per-user SQLite conversation memory
- Queue system so only one inference runs at a time
- `/search` lightweight web search command
- `/shell` owner-only shell command
- AI can call tools with:
  - `[[search: query]]`
  - `[[shell: command]]`
- TinyDolphin fast model installer
- Optional legacy BitNet Heretic model installer
- Optional systemd auto-start service

---

## Requirements

### Raspberry Pi

Recommended:

| Item | Recommendation |
|---|---|
| Hardware | Raspberry Pi 4 Model B |
| RAM | 4 GB+ preferred |
| OS | Raspberry Pi OS 64-bit Bookworm |
| Python | 3.11+ |
| Storage | Several GB free |
| Network | Internet for install/downloads |

Check architecture:

```bash
uname -m
```

You want:

```text
aarch64
```

### Discord bot requirements

In the Discord Developer Portal:

1. Create an application and bot.
2. Copy the bot token.
3. Enable **Message Content Intent** if you want `@mentions`, replies, and normal message chat to work.
4. Invite the bot to your server with bot/application command permissions.

---

# Setup path A: Raspberry Pi 4 only

Use this if you want to do everything directly on the Raspberry Pi.

## 1. Clone the repo

```bash
cd ~
mkdir -p Jimmy-2
cd Jimmy-2
git clone https://github.com/clogan9019-dotcom/Jimmy-discord.git
cd Jimmy-discord
```

If you already cloned it:

```bash
cd ~/Jimmy-2/Jimmy-discord
git pull --ff-only
```

If `git pull` complains about local `config.yaml` changes and you want GitHub's version:

```bash
git restore config.yaml
git pull --ff-only
```

## 2. Install TinyDolphin on the Pi

```bash
cd ~/Jimmy-2/Jimmy-discord
chmod +x install_tinydolphin.sh
bash install_tinydolphin.sh
```

The installer will:

1. Install system packages.
2. Create/update `.venv`.
3. Build `llama-cli` locally for the Pi.
4. Download TinyDolphin if it is not already present.
5. Update `config.yaml` to use TinyDolphin.
6. Back up old `memory.db` if present.

The model ends up here:

```text
models/tinydolphin/tinydolphin-2.8.1-1.1b-q4_k_m.gguf
```

## 3. Set the Discord token

Recommended: use an environment file, not `config.yaml`.

```bash
read -s -p "Paste Discord bot token: " TOKEN
echo
printf 'DISCORD_TOKEN=%s\n' "$TOKEN" > ~/.jimmy-discord.env
chmod 600 ~/.jimmy-discord.env
unset TOKEN
```

For manual testing in the current terminal:

```bash
set -a
source ~/.jimmy-discord.env
set +a
```

## 4. Start manually

```bash
cd ~/Jimmy-2/Jimmy-discord
source .venv/bin/activate
python bot.py
```

Wait for:

```text
Bot ready!
```

Then try in Discord:

```text
@Jimmy hello
```

or:

```text
/chat hello
```

---

# Setup path B: Windows main computer + Raspberry Pi 4

Use this if your Pi downloads slowly or you want to download the AI file on your main PC and copy it over.

## 1. Download the TinyDolphin GGUF on Windows

Install aria2:

```powershell
winget install aria2.aria2
```

Open a new PowerShell, then run:

```powershell
mkdir "C:\Users\cgrif\Projects\Jimmy 2\Jimmy-discord\models\tinydolphin" -Force
cd "C:\Users\cgrif\Projects\Jimmy 2\Jimmy-discord\models\tinydolphin"

aria2c -x16 -s16 -k1M -c -o tinydolphin-2.8.1-1.1b-q4_k_m.gguf "https://huggingface.co/v8karlo/UNCENSORED-TinyDolphin-2.8.1-1.1b-Q4_K_M-GGUF/resolve/main/tinydolphin-2.8.1-1.1b-q4_k_m.gguf?download=true"
```

If it is unstable or throttled, use fewer connections:

```powershell
aria2c -x8 -s8 -k1M -c -o tinydolphin-2.8.1-1.1b-q4_k_m.gguf "https://huggingface.co/v8karlo/UNCENSORED-TinyDolphin-2.8.1-1.1b-Q4_K_M-GGUF/resolve/main/tinydolphin-2.8.1-1.1b-q4_k_m.gguf?download=true"
```

Verify the file:

```powershell
Get-Item "C:\Users\cgrif\Projects\Jimmy 2\Jimmy-discord\models\tinydolphin\tinydolphin-2.8.1-1.1b-q4_k_m.gguf" | Select-Object FullName,Length,@{Name="GB";Expression={[math]::Round($_.Length / 1GB, 2)}}
```

Expected size is about `0.62 GB`.

## 2. Find the Pi IP

On the Pi:

```bash
hostname -I
```

Example:

```text
192.168.5.193 fdab:...
```

Use the IPv4 address, for example:

```text
192.168.5.193
```

## 3. Copy the model to the Pi

From Windows PowerShell:

```powershell
ssh clogan@192.168.5.193 "mkdir -p ~/Jimmy-2/Jimmy-discord/models/tinydolphin"

scp "C:\Users\cgrif\Projects\Jimmy 2\Jimmy-discord\models\tinydolphin\tinydolphin-2.8.1-1.1b-q4_k_m.gguf" clogan@192.168.5.193:~/Jimmy-2/Jimmy-discord/models/tinydolphin/tinydolphin-2.8.1-1.1b-q4_k_m.gguf
```

If your file downloaded to the repo root instead, use that path:

```powershell
scp "C:\Users\cgrif\Projects\Jimmy 2\Jimmy-discord\tinydolphin-2.8.1-1.1b-q4_k_m.gguf" clogan@192.168.5.193:~/Jimmy-2/Jimmy-discord/models/tinydolphin/tinydolphin-2.8.1-1.1b-q4_k_m.gguf
```

## 4. Finish setup on the Pi

```bash
cd ~/Jimmy-2/Jimmy-discord
git pull --ff-only
chmod +x install_tinydolphin.sh
bash install_tinydolphin.sh
```

The installer should detect the model and skip downloading it again.

Then start the bot:

```bash
source .venv/bin/activate
python bot.py
```

---

# Setup path C: Linux main computer + Raspberry Pi 4

Use this if your main computer runs Linux and you want to download the model there first.

## 1. Download on Linux main computer

```bash
mkdir -p ~/Jimmy-discord-models/tinydolphin
cd ~/Jimmy-discord-models/tinydolphin

aria2c -x16 -s16 -k1M -c \
  -o tinydolphin-2.8.1-1.1b-q4_k_m.gguf \
  "https://huggingface.co/v8karlo/UNCENSORED-TinyDolphin-2.8.1-1.1b-Q4_K_M-GGUF/resolve/main/tinydolphin-2.8.1-1.1b-q4_k_m.gguf?download=true"
```

If you do not have aria2:

```bash
sudo apt-get install -y aria2
```

Or use curl:

```bash
curl -L --fail --continue-at - \
  -o tinydolphin-2.8.1-1.1b-q4_k_m.gguf \
  "https://huggingface.co/v8karlo/UNCENSORED-TinyDolphin-2.8.1-1.1b-Q4_K_M-GGUF/resolve/main/tinydolphin-2.8.1-1.1b-q4_k_m.gguf?download=true"
```

## 2. Copy to Pi

Replace the IP with your Pi IP:

```bash
ssh clogan@192.168.5.193 "mkdir -p ~/Jimmy-2/Jimmy-discord/models/tinydolphin"

scp ~/Jimmy-discord-models/tinydolphin/tinydolphin-2.8.1-1.1b-q4_k_m.gguf \
  clogan@192.168.5.193:~/Jimmy-2/Jimmy-discord/models/tinydolphin/tinydolphin-2.8.1-1.1b-q4_k_m.gguf
```

## 3. Finish on Pi

```bash
cd ~/Jimmy-2/Jimmy-discord
git pull --ff-only
bash install_tinydolphin.sh
source .venv/bin/activate
python bot.py
```

---

# Optional: legacy BitNet Heretic model

The original BitNet Heretic model is still supported, but it is much slower and more complicated.

Model:

```text
askalgore/bitnet-b1.58-2B-4T-heretic
```

Final expected model path:

```text
models/heretic/ggml-model-i2_s.gguf
```

Pi-only legacy setup:

```bash
cd ~/Jimmy-2/Jimmy-discord
bash install.sh
```

If using a Windows PC to help conversion:

```powershell
git pull
.\install_windows.bat
```

Depending on whether Windows/WSL quantization succeeds, transfer either:

```text
models\heretic\ggml-model-i2_s.gguf
```

or:

```text
models\heretic\model-f16.gguf
```

If you transfer `model-f16.gguf`, run this on the Pi afterward:

```bash
cd ~/Jimmy-2/Jimmy-discord
git pull --ff-only
bash install.sh
```

The Pi will quantize:

```text
model-f16.gguf -> ggml-model-i2_s.gguf
```

---

## Configuration

Current default `config.yaml` uses TinyDolphin:

```yaml
discord:
  token: ""

bitnet:
  src_dir: "./bitnet_cpp_src"
  model: "./models/tinydolphin/tinydolphin-2.8.1-1.1b-q4_k_m.gguf"
  threads: 4
  context: 2048
  temperature: 0.7
  top_p: 0.9
  top_k: 40
  repeat_penalty: 1.1
  max_tokens: 512

database:
  file: "memory.db"

logging:
  level: "INFO"
```

If replies are too short, increase:

```yaml
max_tokens: 768
```

If replies are too slow, reduce:

```yaml
max_tokens: 192
context: 1024
```

---

## Discord token

The bot reads the token from either:

1. `DISCORD_TOKEN` environment variable, or
2. `config.yaml` under `discord.token`.

Recommended for manual testing:

```bash
export DISCORD_TOKEN="your_token_here"
source .venv/bin/activate
python bot.py
```

Recommended for systemd:

```bash
read -s -p "Paste Discord bot token: " TOKEN
echo
printf 'DISCORD_TOKEN=%s\n' "$TOKEN" > ~/.jimmy-discord.env
chmod 600 ~/.jimmy-discord.env
unset TOKEN
```

Avoid committing real tokens to GitHub.

---

## Running as a systemd service

Create the service on the Pi:

```bash
cd ~/Jimmy-2/Jimmy-discord

cat > /tmp/jimmy-discord.service <<'EOF'
[Unit]
Description=Jimmy Discord AI Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=clogan
WorkingDirectory=/home/clogan/Jimmy-2/Jimmy-discord
EnvironmentFile=/home/clogan/.jimmy-discord.env
Environment=PYTHONUNBUFFERED=1
ExecStart=/home/clogan/Jimmy-2/Jimmy-discord/.venv/bin/python /home/clogan/Jimmy-2/Jimmy-discord/bot.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo mv /tmp/jimmy-discord.service /etc/systemd/system/jimmy-discord.service
sudo systemctl daemon-reload
sudo systemctl enable jimmy-discord
sudo systemctl restart jimmy-discord
sudo systemctl status jimmy-discord --no-pager
```

From Windows PowerShell, the useful commands are:

```powershell
ssh -t clogan@192.168.5.193 "sudo systemctl status jimmy-discord --no-pager"
ssh -t clogan@192.168.5.193 "sudo journalctl -u jimmy-discord -f"
ssh -t clogan@192.168.5.193 "sudo systemctl restart jimmy-discord"
```

Disable autostart:

```bash
sudo systemctl disable --now jimmy-discord
```

Remove the service:

```bash
sudo systemctl stop jimmy-discord
sudo systemctl disable jimmy-discord
sudo rm -f /etc/systemd/system/jimmy-discord.service
sudo systemctl daemon-reload
sudo systemctl reset-failed
```

---

## Logs

Live logs:

```bash
sudo journalctl -u jimmy-discord -f
```

Last 200 lines:

```bash
sudo journalctl -u jimmy-discord -n 200 --no-pager
```

Since boot:

```bash
sudo journalctl -u jimmy-discord -b --no-pager
```

From Windows:

```powershell
ssh -t clogan@192.168.5.193 "sudo journalctl -u jimmy-discord -n 200 --no-pager"
```

---

## Commands

| Command | Description |
|---|---|
| `/chat <message>` | Chat with the model |
| `/search <query>` | Lightweight web search |
| `/shell <command>` | Owner-only shell command on the Pi |
| `/history [count]` | Show recent memory |
| `/reset` | Clear your memory |
| `/clear` | Alias for reset |
| `/ping` | Latency check |
| `/stats` | Bot/model stats |
| `/help` | Help message |

Normal message triggers:

- `@Jimmy hello`
- Reply to one of Jimmy's messages
- DM the bot

Tool examples:

```text
@Jimmy search current Raspberry Pi OS version
@Jimmy check disk space with shell
@Jimmy shell uptime
```

The AI is also instructed that it can call:

```text
[[search: query]]
[[shell: command]]
```

Shell is owner-only.

---

## Security notes

- Do not commit your Discord token.
- `/shell` is powerful. It is owner-only, but still treat it like giving yourself remote terminal access through Discord.
- Search uses DuckDuckGo HTML results and does not require an API key.
- Message Content Intent must be enabled for mentions/replies to work.
- Per-user memory is stored in SQLite.

---

## Troubleshooting

### `ModuleNotFoundError: No module named 'discord'`

You used system Python instead of the venv.

Use:

```bash
cd ~/Jimmy-2/Jimmy-discord
source .venv/bin/activate
python bot.py
```

or:

```bash
./.venv/bin/python bot.py
```

### `No Discord token found`

Set `DISCORD_TOKEN` or put the token in `config.yaml`.

For systemd, make sure the service has:

```ini
EnvironmentFile=/home/clogan/.jimmy-discord.env
```

and the file exists:

```bash
cat ~/.jimmy-discord.env
```

### `Unknown interaction`

Usually caused by duplicate bot instances or the Pi being overloaded.

```bash
pkill -f "python.*bot.py" 2>/dev/null || true
sudo systemctl stop jimmy-discord 2>/dev/null || true
pgrep -af "bot.py|jimmy-discord"
```

Then start exactly one copy.

### Bot keeps printing old error messages

Clear memory:

```bash
rm -f memory.db
```

### Git pull refuses because `config.yaml` changed

If you want GitHub's config:

```bash
git restore config.yaml
git pull --ff-only
```

### `SIGILL` / illegal instruction

The Pi binary was compiled with unsupported CPU instructions.

```bash
cd ~/Jimmy-2/Jimmy-discord
git pull --ff-only
rm -rf bitnet_cpp_src/build
bash install_tinydolphin.sh
```

Let warnings pass. Only worry about `error:`, `FAILED:`, or `ninja: build stopped`.

### Model file not found

Check:

```bash
ls -lh models/tinydolphin/
grep -A20 '^bitnet:' config.yaml
```

The configured model path must exist.

### See all auto-start logs

```bash
sudo journalctl -u jimmy-discord --no-pager
```

---

## Project structure

```text
Jimmy-discord/
├── bot.py
├── config.yaml
├── install.sh                    # legacy BitNet Heretic installer
├── install_tinydolphin.sh        # recommended fast TinyDolphin installer
├── install_windows.ps1           # Windows helper for legacy BitNet conversion
├── install_windows.bat
├── requirements.txt
├── bitnet/
├── commands/
├── database/
├── utils/
├── models/
│   ├── tinydolphin/
│   └── heretic/
├── logs/
└── memory.db
```

---

## Recommended daily workflow

Update and restart:

```bash
cd ~/Jimmy-2/Jimmy-discord
git pull --ff-only
sudo systemctl restart jimmy-discord
sudo journalctl -u jimmy-discord -f
```

Manual run:

```bash
cd ~/Jimmy-2/Jimmy-discord
pkill -f "python.*bot.py" 2>/dev/null || true
source .venv/bin/activate
python bot.py
```
