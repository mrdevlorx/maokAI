# maok A.I.

> ⚠️ **DISCLAIMER & TOS NOTICE:** This bot relies exclusively on Riot's own internal client APIs (LCU API). However, automated chat interaction may violate Riot Games' Terms of Service (ToS). Use strictly at your own risk — the author assumes no responsibility for any banned or restricted accounts.

Lightweight Windows PowerShell script that bridges the **Riot Client (League of Legends)** LCU chat system to any **OpenAI-compatible LLM** endpoint. Listens for incoming chat messages via the local LCU REST API, resolves sender identity, generates an in-character reply via the LLM, and posts it back into the conversation.

Built 100% natively in **PowerShell** (`maokAI.ps1`) — no Python, `pip`, or external package installation required.

---

## Features

- **Zero External Dependencies** — written purely in Windows PowerShell using native .NET classes (`System.Net.WebClient`).
- **LCU Auto-Discovery** — reads dynamic HTTPS port and auth token from `lockfile`, `scope_v3.json`, or running `RiotClientUx.exe` process args.
- **Sender Identity Resolution** — looks up friend name and tag in real-time.
- **OpenAI API Standard** — talks to any server exposing `/v1/chat/completions` (LM Studio, vLLM, Ollama, OpenAI, etc.).
- **Persona Enforcement** — system prompt keeps replies concise and in character (maok A.I.).
- **Anti-Spam Controls** — per-chat cooldown + 15 messages / 10 s global cap.

---

## Architecture

```
+-----------------------------------------------------------------------------------+
|                                 RIOT CLIENT                                       |
|  (lockfile + scope_v3.json + RiotClientUx.exe process args)                       |
+----------------------------------------+------------------------------------------+
                                         | (REST API, basic auth "riot:<token>")
                                         v
+-----------------------------------------------------------------------------------+
|                                    MAOKAI.PS1                                     |
|                                                                                   |
|  1. Auto-discovers LCU port & auth token (env > lockfile > process args)          |
|  2. Polls messages & resolves sender identity                                     |
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

## Quickstart

Run directly in Windows PowerShell (no setup required):

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\maokAI.ps1
```

---

## Configuration

All configuration is via environment variables or directly at the top of `maokAI.ps1`.

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
├── maokAI.ps1          # PowerShell bot script
├── .gitignore          # Git ignore rules
├── LICENSE             # MIT License
└── README.md           # Documentation
```

---

## Disclaimer

For educational purposes and local testing only. Use responsibly and in accordance with Riot Games' Terms of Service.
