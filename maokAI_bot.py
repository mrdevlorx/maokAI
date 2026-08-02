"""
Riot Client AI Chatbot (maokAI - Champion Persona)
--------------------------------------------------
Persona: maokAI (Maokai the Treant from League of Legends)

Hooks into the local Riot Client UX API via WebSockets to intercept incoming
chat messages and respond as Maokai using any OpenAI-compatible LLM endpoint.
"""

import asyncio
import json
import os
import re
import ssl
import sys
import time
import base64
import subprocess
import io
import random
from pathlib import Path
from datetime import datetime

# Windows console UTF-8 encoding fix
if sys.platform == "win32":
    os.system("chcp 65001 >nul 2>&1")
    try:
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
        sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")
    except Exception:
        pass

try:
    import requests
    from requests.auth import HTTPBasicAuth
except ImportError:
    print("[!] Missing 'requests' package. Install it with: pip install requests")
    sys.exit(1)

try:
    import websockets
except ImportError:
    print("[!] Missing 'websockets' package. Install it with: pip install websockets")
    sys.exit(1)

# ===================================================================
# 🎛️ USER CONFIGURATION & SYSTEM PROMPT (EDIT HERE)
# ===================================================================

# 1. LLM API Endpoint Settings (LM Studio, Ollama, OpenAI, vLLM, etc.)
LLM_BASE_URL = os.getenv("OPENAI_BASE_URL", "http://localhost:8080/v1")
LLM_API_KEY = os.getenv("OPENAI_API_KEY", "lm-studio")
LLM_MODEL = os.getenv("OPENAI_MODEL", "local-model")

# 2. System Prompt / Bot Persona
CHATBOT_SYSTEM_PROMPT = """You are maokAI, the ancient and powerful treant spirit Maokai from League of Legends.

RULES:
- NEVER state "I am an AI model" or break character.
- Speak in English as Maokai (nature-focused, wise, deep-voiced, referencing roots, branches, saplings, and protecting the forest).
- Keep replies brief and impactful (1-3 sentences max).
- Do not show chain-of-thought or reasoning out loud; respond directly as Maokai."""

# 3. Fallback Responses (used if LLM API is unreachable or returns empty output)
DEFAULT_FALLBACKS = [
    "Greetings, young sapling. The ancient roots feel your footsteps. What brings you to maokAI?",
    "The forest listens to your words. How can maokAI assist you today?",
    "My branches sway in the wind. Speak, what is on your mind?"
]

# 4. Anti-Spam & Rate Limiting Settings
COOLDOWN_PER_CHAT_SECONDS = 1.0    # Minimum delay between replies to the same person
GLOBAL_MAX_RESPONSES_PER_10S = 15  # Max total replies across all chats per 10 seconds

# ===================================================================
# ⚙️ SYSTEM & INTERNAL SETTINGS
# ===================================================================

# File to persist conversation history per chat ID
HISTORY_FILE = Path("chat_history.json")

# Standard paths where Riot Client writes its lockfile during execution
LOCKFILE_PATHS = [
    Path(os.environ.get("LOCALAPPDATA", "")) / "Riot Games" / "Riot Client" / "Config" / "lockfile",
    Path("C:/Riot Games/Riot Client/lockfile"),
    Path("C:/Riot Games/League of Legends/lockfile"),
]

# Secondary config path containing local API endpoints
SCOPE_V3_PATH = Path(os.environ.get("APPDATA", "")) / "riot-client-ux" / "sentry" / "scope_v3.json"

POLL_INTERVAL = 2.0
TEST_MODE = False

# ===================================================================
# Terminal Output Utilities
# ===================================================================

class Colors:
    HEADER = "\033[95m"
    BLUE = "\033[94m"
    CYAN = "\033[96m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    RED = "\033[91m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RESET = "\033[0m"

def log(msg, color=Colors.RESET):
    """Prints timestamped colored logs to stdout."""
    timestamp = datetime.now().strftime("%H:%M:%S")
    print(f"{Colors.DIM}[{timestamp}]{Colors.RESET} {color}{msg}{Colors.RESET}", flush=True)

def log_header():
    print(f"""{Colors.GREEN}{Colors.BOLD}
    +-----------------------------------------------------------+
    |  maokAI CHATBOT (Maokai Persona)                          |
    |  Target LLM: {LLM_BASE_URL}
    +-----------------------------------------------------------+
    {Colors.RESET}""", flush=True)

# ===================================================================
# Rate Limiting & Anti-Spam
# ===================================================================

class AntiSpamManager:
    """Manages chat cooldowns and rate limits to prevent spamming the client."""
    def __init__(self, cooldown_per_chat=COOLDOWN_PER_CHAT_SECONDS, max_global_per_10s=GLOBAL_MAX_RESPONSES_PER_10S):
        self.cooldown_per_chat = cooldown_per_chat
        self.max_global_per_10s = max_global_per_10s
        self.last_sent_time = {}
        self.global_send_history = []

    def is_allowed(self, cid, text):
        now = time.time()
        # Per-chat cooldown check
        if now - self.last_sent_time.get(cid, 0) < self.cooldown_per_chat:
            log(f"  [ANTI-SPAM] Cooldown active (< {self.cooldown_per_chat}s)", Colors.YELLOW)
            return False

        # Global rate limit check (sliding 10s window)
        self.global_send_history = [t for t in self.global_send_history if now - t < 10.0]
        if len(self.global_send_history) >= self.max_global_per_10s:
            log(f"  [ANTI-SPAM] Global rate limit hit", Colors.YELLOW)
            return False

        self.last_sent_time[cid] = now
        self.global_send_history.append(now)
        return True

anti_spam = AntiSpamManager()

# ===================================================================
# 1. Lockfile & Port Discovery
# ===================================================================

def read_lockfile():
    """Reads Riot Client credentials from env vars, lockfile, or process args."""
    # Check for manual environment variable overrides
    manual_port = os.getenv("RIOT_CLIENT_PORT")
    manual_token = os.getenv("RIOT_CLIENT_AUTH_TOKEN")
    if manual_port and manual_token:
        log(f"Using manual credentials from environment variables: Port={manual_port}", Colors.GREEN)
        return int(manual_port), manual_token, "https"

    # Search standard lockfile locations
    for path in LOCKFILE_PATHS:
        if path.exists():
            log(f"Found lockfile: {path}", Colors.GREEN)
            content = path.read_text().strip()
            # Lockfile format: process_name:pid:port:password:protocol
            parts = content.split(":")
            if len(parts) >= 5:
                port = int(parts[2])
                password = parts[3]
                protocol = parts[4]
                log(f"  Port: {port} | Token: {password[:6]}...", Colors.CYAN)
                return port, password, protocol

    log("Lockfile not found in standard paths. Inspecting process arguments...", Colors.YELLOW)
    return read_from_process()

def read_from_process():
    """Fallback method: inspects running process commandline args via WMIC on Windows."""
    try:
        result = subprocess.run(
            ["wmic", "process", "where", "name='RiotClientUx.exe'", "get", "commandline"],
            capture_output=True, text=True, timeout=10
        )
        output = result.stdout
        port_match = re.search(r"--app-port=(\d+)", output)
        token_match = re.search(r"--remoting-auth-token=([\w\-_]+)", output)
        if port_match and token_match:
            port = int(port_match.group(1))
            password = token_match.group(1)
            log(f"  Extracted from process: Port={port}", Colors.GREEN)
            return port, password, "https"
    except Exception as e:
        log(f"  Failed reading process commandline: {e}", Colors.RED)
    return None, None, None

# ===================================================================
# 2. Additional Port Discovery
# ===================================================================

def parse_scope_v3():
    """Parses scope_v3.json for candidate localhost API endpoints."""
    if not SCOPE_V3_PATH.exists():
        return []
    content = SCOPE_V3_PATH.read_text(encoding="utf-8", errors="ignore")
    url_pattern = r"https?://127\.0\.0\.1:\d+"
    return sorted(set(re.findall(url_pattern, content)))

def discover_api_port(lockfile_port, password, scope_urls):
    """Tests candidates to verify a responsive LCU HTTPS API port."""
    if lockfile_port:
        base = f"https://127.0.0.1:{lockfile_port}"
        try:
            resp = requests.get(f"{base}/chat/v6/messages", auth=HTTPBasicAuth("riot", password), verify=False, timeout=3)
            if resp.status_code in (200, 204):
                return base
        except Exception:
            pass

    for url in scope_urls:
        if "https://" in url:
            try:
                resp = requests.get(f"{url}/chat/v6/messages", auth=HTTPBasicAuth("riot", password), verify=False, timeout=3)
                if resp.status_code in (200, 204):
                    return url
            except Exception:
                pass
    return None

# ===================================================================
# 3. Riot LCU HTTP Client Interface
# ===================================================================

class RiotAPI:
    """Wrapper around the local Riot Client REST API endpoints."""
    def __init__(self, base_url, password):
        self.base_url = base_url
        self.auth = HTTPBasicAuth("riot", password)
        self.password = password
        self.session = requests.Session()
        self.session.auth = self.auth
        self.session.verify = False # Ignore self-signed local certs
        self.session.headers.update({"Content-Type": "application/json"})
        port_match = re.search(r":(\d+)", base_url)
        self.port = int(port_match.group(1)) if port_match else 0

    def get(self, endpoint):
        try:
            return self.session.get(f"{self.base_url}{endpoint}", timeout=5)
        except Exception:
            return None

    def post(self, endpoint, data=None):
        try:
            return self.session.post(f"{self.base_url}{endpoint}", json=data, timeout=5)
        except Exception:
            return None

    def get_messages(self):
        """Fetches recent chat messages across conversations."""
        resp = self.get("/chat/v6/messages")
        if resp and resp.status_code == 200:
            data = resp.json()
            if isinstance(data, dict) and "messages" in data:
                return data["messages"]
            if isinstance(data, list):
                return data
        return []

    def send_message(self, cid, body):
        """Sends a text reply back into a specific Riot chat conversation."""
        data = {"cid": cid, "message": body, "type": "chat"}
        resp = self.post("/chat/v6/messages", data)
        if resp and resp.status_code in (200, 201):
            log(f"  -> Message delivered to chat", Colors.GREEN)
            return True
        return False

    def get_me(self):
        """Returns session details for the logged-in player."""
        resp = self.get("/chat/v1/session")
        if resp and resp.status_code == 200:
            return resp.json()
        return {}

    def get_friends(self):
        """Returns the active friends list."""
        resp = self.get("/social/v4/friends")
        if resp and resp.status_code == 200:
            data = resp.json()
            if isinstance(data, dict) and "friends" in data:
                return data["friends"]
            if isinstance(data, list):
                return data
        return []

    def get_friend_by_cid(self, cid):
        """Resolves conversation ID to friend metadata (game name, tag)."""
        if not cid:
            return None
        target_puuid = cid.split("@")[0]
        friends = self.get_friends()
        for f in friends:
            if f.get("puuid") == target_puuid or f.get("pid") == cid:
                return f
        return None

# ===================================================================
# 4. LLM Request Processing
# ===================================================================

class AIChatLLM:
    """Manages chat history and generates responses via OpenAI Chat Completion API."""
    def __init__(self, base_url=LLM_BASE_URL, model=LLM_MODEL, api_key=LLM_API_KEY):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api_key = api_key
        self.conversation_histories = {}
        self.max_history = 5
        self.load_history()

    def load_history(self):
        """Loads saved chat history from disk."""
        if HISTORY_FILE.exists():
            try:
                data = json.loads(HISTORY_FILE.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    self.conversation_histories = data
            except Exception:
                pass

    def save_history(self):
        """Saves current conversation history to disk."""
        try:
            HISTORY_FILE.write_text(json.dumps(self.conversation_histories, indent=2, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass

    def generate_response(self, user_message, cid="default", friend_name="Friend"):
        """Sends chat history to LLM and returns formatted response."""
        history = self.conversation_histories.setdefault(cid, [])
        history.append({"role": "user", "content": user_message})

        # Keep a sliding window of recent history
        if len(history) > self.max_history * 2:
            history = history[-(self.max_history * 2):]
            self.conversation_histories[cid] = history

        system_prompt = CHATBOT_SYSTEM_PROMPT + f"\nYou are currently chatting with {friend_name}."

        messages = [{"role": "system", "content": system_prompt}]
        messages.extend(history)

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}"
        }

        try:
            resp = requests.post(
                f"{self.base_url}/chat/completions",
                headers=headers,
                json={
                    "model": self.model,
                    "messages": messages,
                    "max_tokens": 250,
                    "temperature": 0.7
                },
                timeout=60
            )
            if resp.status_code == 200:
                data = resp.json()
                msg_obj = data["choices"][0]["message"]
                raw_text = msg_obj.get("content", "") or ""
                
                clean_text = raw_text.replace("\n\n", " ").replace("\n", " ").strip()

                if len(clean_text.split()) < 2:
                    clean_text = random.choice(DEFAULT_FALLBACKS)

                history.append({"role": "assistant", "content": clean_text})
                self.save_history()
                return clean_text
            else:
                log(f"  [LLM Error] HTTP {resp.status_code}: {resp.text}", Colors.RED)
                return random.choice(DEFAULT_FALLBACKS)
        except Exception as e:
            log(f"  [LLM Exception] {e}", Colors.RED)
            return random.choice(DEFAULT_FALLBACKS)

# ===================================================================
# 5. Real-Time WebSocket Event Listener
# ===================================================================

async def websocket_listener(riot_api, llm, my_puuid):
    """Establishes SSL WebSocket connection to LCU and listens for chat events."""
    ws_url = f"wss://riot:{riot_api.password}@127.0.0.1:{riot_api.port}/"

    # Disable SSL verification for local client certificate
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    log("Connecting WebSocket...", Colors.BLUE)

    try:
        async with websockets.connect(
            ws_url,
            ssl=ssl_context,
            additional_headers={
                "Authorization": "Basic " + base64.b64encode(f"riot:{riot_api.password}".encode()).decode()
            },
            ping_interval=30,
            ping_timeout=10,
        ) as ws:
            log("WebSocket connected!", Colors.GREEN)

            # Subscribe to Riot Client JSON API events
            await ws.send(json.dumps([5, "OnJsonApiEvent"]))

            log("", Colors.RESET)
            log("maokAI is active and listening for messages...", Colors.BOLD)
            log("", Colors.RESET)

            # Mark pre-existing messages as read so we don't re-trigger on old chat
            seen_ids = set()
            initial_msgs = riot_api.get_messages()
            for m in initial_msgs:
                mid = m.get("mid", m.get("id", ""))
                if mid:
                    seen_ids.add(mid)
            log(f"  Ignored {len(seen_ids)} existing historical messages", Colors.DIM)

            async for raw_msg in ws:
                try:
                    data = json.loads(raw_msg)
                    await handle_ws_event(data, riot_api, llm, my_puuid, seen_ids)
                except Exception:
                    pass

    except Exception as e:
        log(f"WebSocket error: {e}", Colors.YELLOW)
        return False

    return True

async def handle_ws_event(data, riot_api, llm, my_puuid, seen_ids):
    """Processes incoming WebSocket event payloads and triggers AI responses."""
    if not isinstance(data, list) or len(data) < 3:
        return

    payload = data[2] if len(data) > 2 else {}
    if not isinstance(payload, dict):
        return

    uri = payload.get("uri", "")
    if "chat" not in uri.lower() and "message" not in uri.lower():
        return

    all_messages = riot_api.get_messages()

    for msg in all_messages:
        mid = msg.get("mid", msg.get("id", ""))
        if mid and mid in seen_ids:
            continue
        if mid:
            seen_ids.add(mid)

        sender_id = msg.get("pid", msg.get("puuid", ""))
        body = msg.get("body", msg.get("message", ""))
        cid = msg.get("cid", "")
        msg_type = msg.get("type", "chat")

        # Ignore self messages unless test mode is enabled
        is_own = (sender_id == my_puuid)
        if is_own and not TEST_MODE:
            continue

        if not body or not body.strip():
            continue
        if msg_type not in ("chat", "groupchat", "normal", ""):
            continue

        friend_info = riot_api.get_friend_by_cid(cid)
        friend_name = f"{friend_info.get('gameName')}#{friend_info.get('gameTag')}" if friend_info else "Player"
        log(f"  << Message from {friend_name}: \"{body}\"", Colors.CYAN)

        # Generate response using LLM
        response = llm.generate_response(body, cid=cid, friend_name=friend_name)

        # Check anti-spam limits before delivering
        if not anti_spam.is_allowed(cid, response):
            log("  [ANTI-SPAM] Message suppressed", Colors.YELLOW)
            continue

        log(f"  >> maokAI: \"{response}\"", Colors.GREEN)

        if cid:
            riot_api.send_message(cid, response)
            await asyncio.sleep(0.5)
            # Update seen message IDs
            new_msgs = riot_api.get_messages()
            for nm in new_msgs:
                nmid = nm.get("mid", nm.get("id", ""))
                if nmid:
                    seen_ids.add(nmid)

# ===================================================================
# 6. Main Application Loop
# ===================================================================

async def main():
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    log_header()

    # Step 1: Discover API connection parameters
    port, password, protocol = read_lockfile()
    if not password:
        log("Unable to locate auth password! Ensure Riot Client is running.", Colors.RED)
        sys.exit(1)

    scope_urls = parse_scope_v3()
    api_base = discover_api_port(port, password, scope_urls)
    if not api_base:
        log("No reachable Riot LCU endpoint found!", Colors.RED)
        sys.exit(1)
    log(f"Connected to Riot API: {api_base}", Colors.GREEN)

    # Step 2: Initialize API and session
    riot_api = RiotAPI(api_base, password)
    session = riot_api.get_me()
    my_puuid = session.get("puuid", session.get("pid", ""))
    my_name = session.get("game_name", session.get("name", "Unknown"))
    log(f"  Logged in as: {my_name}", Colors.CYAN)

    # Step 3: Initialize LLM handler
    llm = AIChatLLM()

    log("", Colors.RESET)
    log(f"=== Message Listener Started ===", Colors.BOLD)

    # Step 4: Run persistent WebSocket listener with auto-reconnect
    while True:
        try:
            ws_success = await websocket_listener(riot_api, llm, my_puuid)
            if not ws_success:
                log("WebSocket dropped, reconnecting in 5s...", Colors.YELLOW)
                await asyncio.sleep(5)
        except Exception:
            await asyncio.sleep(5)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print(f"\n{Colors.RED}maokAI returning to the earth...{Colors.RESET}")
        sys.exit(0)
