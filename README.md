# Discord BitNet Bot

A production-ready Discord AI chatbot powered by **[bitnet.cpp](https://github.com/microsoft/BitNet)** and the [`askalgore/bitnet-b1.58-2B-4T-heretic`](https://huggingface.co/askalgore/bitnet-b1.58-2B-4T-heretic) model.

All inference runs **entirely on-device** on a Raspberry Pi 4. No data is ever sent to OpenAI, Anthropic, Groq, Ollama, or any other external AI API.

---

## Features

- **Local-only inference** via bitnet.cpp — zero external AI API calls
- **Slash commands** — `/chat`, `/reset`, `/history`, `/clear`, `/ping`, `/stats`, `/help`
- **Per-user conversation memory** stored in SQLite (users never see each other's context)
- **Streaming responses** — messages are edited in real time as tokens arrive
- **Single-concurrency queue** — only one inference at a time, with position reporting
- **Automatic crash recovery** — the bitnet.cpp process restarts with exponential back-off
- **Rotating log files** — logs stored in `logs/`
- **Raspberry Pi 4 optimised** — ARM64, configurable threads, async everywhere

---

## Requirements

| Component | Version |
|-----------|---------|
| Hardware | Raspberry Pi 4 Model B (4 GB+ recommended) |
| OS | Raspberry Pi OS 64-bit (Bookworm/Bullseye) |
| Python | 3.11+ |
| discord.py | 2.x |
| bitnet.cpp | latest main |

---

## Installation

```bash
git clone <this-repo> discord-bitnet-bot
cd discord-bitnet-bot
chmod +x install.sh
./install.sh
```

The installer will:
1. Update `apt` and install build tools
2. Create a Python virtual environment
3. Install Python dependencies
4. Clone and build `bitnet.cpp` with ARM64 optimisations
5. Prompt you to download the model
6. Guide you through Discord token setup

---

## Configuration

Edit `config.yaml` before running the bot:

```yaml
discord:
  token: ""          # or set DISCORD_TOKEN env var

bitnet:
  executable: "./bitnet"
  model: "./models/heretic"
  threads: 4         # Raspberry Pi 4 has 4 cores
  context: 4096
  temperature: 0.8
  top_p: 0.95
  top_k: 40
  repeat_penalty: 1.1
  max_tokens: 512

database:
  file: "memory.db"

logging:
  level: "INFO"
```

### Discord Token

Set your bot token either in `config.yaml` or as an environment variable:

```bash
export DISCORD_TOKEN="your_token_here"
```

**Never commit your token to version control.**

---

## Model Download

The `bitnet-b1.58-2B-4T-heretic` model must be downloaded from Hugging Face:

```bash
pip install huggingface_hub
huggingface-cli download \
  askalgore/bitnet-b1.58-2B-4T-heretic \
  --local-dir ./models/heretic
```

Or visit: https://huggingface.co/askalgore/bitnet-b1.58-2B-4T-heretic

---

## Running the Bot

```bash
source .venv/bin/activate
python bot.py
```

With a custom config path:

```bash
python bot.py --config /path/to/config.yaml
```

---

## Running as a systemd Service

Create `/etc/systemd/system/discord-bitnet-bot.service`:

```ini
[Unit]
Description=Discord BitNet AI Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/discord-bitnet-bot
Environment=DISCORD_TOKEN=your_token_here
ExecStart=/home/pi/discord-bitnet-bot/.venv/bin/python bot.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable discord-bitnet-bot
sudo systemctl start discord-bitnet-bot
sudo systemctl status discord-bitnet-bot
```

---

## Project Structure

```
discord-bitnet-bot/
│
├── bot.py                  # Main entry point
├── config.yaml             # YAML configuration
├── requirements.txt        # Python dependencies
├── install.sh              # Automated installer
├── README.md
│
├── bitnet/
│   ├── wrapper.py          # High-level BitNetModel async API
│   └── process.py          # Low-level subprocess manager
│
├── commands/
│   ├── chat.py             # /chat slash command
│   ├── history.py          # /history, /reset, /clear commands
│   ├── stats.py            # /stats, /ping commands
│   └── admin.py            # /help command
│
├── database/
│   └── memory.py           # SQLite conversation memory store
│
├── utils/
│   ├── config.py           # YAML config loader with typed accessors
│   ├── logger.py           # Rotating file + console logger setup
│   └── queue.py            # Single-concurrency async inference queue
│
├── models/                 # Place downloaded model files here
│   └── heretic/
│
├── logs/                   # Rotating log files written here
│
└── memory.db               # SQLite database (auto-created)
```

---

## Slash Commands

| Command | Description |
|---------|-------------|
| `/chat <message>` | Send a message to the AI (streams response in real time) |
| `/history [count]` | View your recent conversation history (private, 1–20 messages) |
| `/reset` | Clear your entire conversation history |
| `/clear` | Alias for `/reset` |
| `/ping` | Check websocket latency |
| `/stats` | Show bot uptime, model stats, queue length, tokens/sec |
| `/help` | Show all commands with descriptions |

---

## Queue System

Only **one inference** runs at a time to avoid overloading the Raspberry Pi CPU. When the model is busy:

- Additional requests are placed in a FIFO async queue
- Each user receives a queue position estimate
- The queue processes jobs in order, one at a time

---

## Logging

Logs are written to `logs/bot.log` with automatic rotation (10 MB per file, 5 backups). The console also receives log output. Configure the level in `config.yaml`:

```yaml
logging:
  level: "INFO"   # DEBUG | INFO | WARNING | ERROR | CRITICAL
```

---

## Security Notes

- Never hardcode your Discord bot token in source files
- The `config.yaml` file is excluded from the example — add it to `.gitignore`
- Each user's conversation history is completely isolated in the database
- The bot only reads message content when a slash command is explicitly invoked

---

## Troubleshooting

**Bot starts but `/chat` returns an error:**
- Verify the BitNet executable path in `config.yaml`
- Verify the model files exist in the configured `model` directory
- Check `logs/bot.log` for detailed error messages

**Very slow responses:**
- This is expected on a Raspberry Pi 4; the 2B model takes several seconds per token on CPU
- Reduce `max_tokens` in `config.yaml` for faster replies
- Ensure no other CPU-heavy processes are running

**Bot goes offline after crashes:**
- The systemd service will automatically restart the bot
- Check `sudo journalctl -u discord-bitnet-bot -f` for crash details
