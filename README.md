# maok A.I.

Lightweight connector that bridges the **Riot Client (League of Legends)** LCU chat system to any **OpenAI-compatible LLM** endpoint. Listens for incoming chat messages over the local LCU WebSocket / REST API, generates an in-character reply via the LLM, and posts it back into the conversation.

Available in both **Python** (`maokAI_bot.py`) and **PowerShell** (`maokAI.ps1`).

---

## Features

- **LCU Auto-Discovery** — reads dynamic HTTPS port and auth token from `lockfile`, `scope_v3.json`, or running `RiotClientUx.exe` process args.
- **Dual Runtime Support** — includes both a Python edition (WebSocket-driven) and a native Windows PowerShell edition (`maokAI.ps1`).
- **OpenAI API Standard** — talks to any server exposing `/v1/chat/completions` (LM Studio, vLLM, Ollama, OpenAI, etc.).
- **Persona Enforcement** — system prompt keeps replies concise and in character (maok A.I.).
- **Anti-Spam Controls** — 1 s per-chat cooldown + 15 messages / 10 s global cap.

---

## Architecture

```
+-----------------------------------------------------------------------------------+
|                                 RIOT CLIENT                                       |
|  (lockfile + scope_v3.json + RiotClientUx.exe process args)                       |
+----------------------------------------+------------------------------------------+
                                         | (WebSocket / REST API, basic auth "riot:<token>")
                                         v
+-----------------------------------------------------------------------------------+
|                              MAOKAI_BOT.PY / MAOKAI.PS1                           |
|                                                                                   |
|  1. Auto-discovers LCU port & auth token (env > lockfile > process args)          |
|  2. Subscribes to chat events / polls messages                                    |
|  3. Formats persona prompt + history, POSTs to LLM /chat/completions              |
|  4. Rate-limits and sends response back via LCU REST                              |
+----------------------------------------+------------------------------------------+
                                         | (HTTP POST /v1/chat/completions)
                                         v
+-----------------------------------------------------------------------------------+
|                              OPENAI-COMPATIBLE LLM                                |
|                   (LM Studio / vLLM / Ollama / OpenAI API)                        |
+-----------------------------------------------------------------------------------+
```

---

## Usage

### Python Version (`maokAI_bot.py`)

1. Install requirements:
   ```bash
   pip install -r requirements.txt
   ```
2. Run:
   ```bash
   python maokAI_bot.py
   ```

### PowerShell Version (`maokAI.ps1`)

No Python installation required! Run directly in Windows PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\maokAI.ps1
```

---

## Configuration

All configuration is via environment variables or directly at the top of either script (`maokAI_bot.py` or `maokAI.ps1`).

| Variable                  | Default                     | Description                                              |
|---------------------------|-----------------------------|---------------------------------------------------------|
| `OPENAI_BASE_URL`         | `http://localhost:8080/v1`  | Base URL of the OpenAI-compatible LLM endpoint.         |
| `OPENAI_API_KEY`          | `lm-studio`                 | Bearer token sent to the LLM.                           |
| `OPENAI_MODEL`            | `local-model`               | Model name passed in the completion request.            |
| `RIOT_CLIENT_PORT`        | _(unset)_                   | Manual LCU port override (skips auto-discovery).        |
| `RIOT_CLIENT_AUTH_TOKEN`  | _(unset)_                   | Manual LCU auth token override (skips auto-discovery).  |

---

## Project Structure

```
maokAI/
├── maokAI_bot.py       # Python version (WebSocket + REST)
├── maokAI.ps1          # PowerShell version (Native Windows PowerShell)
├── requirements.txt    # Python dependencies
└── README.md           # Documentation
```

---

## Disclaimer

For educational purposes and local testing only. Use responsibly and in accordance with Riot Games' Terms of Service.
