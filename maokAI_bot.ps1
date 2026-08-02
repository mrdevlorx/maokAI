<#
.SYNOPSIS
    Riot Client AI Chatbot (maokAI - Champion Persona)
.DESCRIPTION
    Hooks into the local Riot Client UX API via WebSocket, intercepts incoming
    chat messages, and responds as Maokai using any OpenAI-compatible LLM endpoint.
#>

# ===================================================================
# 🎛️ USER CONFIGURATION & SYSTEM PROMPT (EDIT HERE)
# ===================================================================

$global:LLM_BASE_URL = if ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL } else { "http://localhost:8080/v1" }
$global:LLM_API_KEY  = if ($env:OPENAI_API_KEY)  { $env:OPENAI_API_KEY }  else { "lm-studio" }
$global:LLM_MODEL    = if ($env:OPENAI_MODEL)    { $env:OPENAI_MODEL }    else { "local-model" }

$global:CHATBOT_SYSTEM_PROMPT = @"
You are maokAI, the ancient and powerful treant spirit Maokai from League of Legends.

RULES:
- NEVER state "I am an AI model" or break character.
- Speak in English as Maokai (nature-focused, wise, deep-voiced, referencing roots, branches, saplings, and protecting the forest).
- Keep replies brief and impactful (1-3 sentences max).
- Do not show chain-of-thought or reasoning out loud; respond directly as Maokai.
"@

$global:DEFAULT_FALLBACKS = @(
    "Greetings, young sapling. The ancient roots feel your footsteps. What brings you to maokAI?",
    "The forest listens to your words. How can maokAI assist you today?",
    "My branches sway in the wind. Speak, what is on your mind?"
)

$global:COOLDOWN_PER_CHAT_SECONDS = 1.0
$global:GLOBAL_MAX_RESPONSES_PER_10S = 15

# ===================================================================
# ⚙️ INTERNAL SETTINGS & CONSTANTS
# ===================================================================

$global:HISTORY_FILE = "chat_history.json"
$global:LastSentTime = @{}
$global:GlobalSendHistory = [System.Collections.Generic.List[double]]::new()

$LockfilePaths = @(
    "$env:LOCALAPPDATA\Riot Games\Riot Client\Config\lockfile",
    "C:\Riot Games\Riot Client\lockfile",
    "C:\Riot Games\League of Legends\lockfile"
)

# Bypass SSL certificate validation for local self-signed certs
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

# ===================================================================
# Helper Functions
# ===================================================================

function Write-Log {
    param([string]$Message, [string]$Color = "Reset")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Read-Lockfile {
    # 1. Manual env overrides
    if ($env:RIOT_CLIENT_PORT -and $env:RIOT_CLIENT_AUTH_TOKEN) {
        Write-Log "Using manual credentials from environment: Port=$env:RIOT_CLIENT_PORT" "Green"
        return @{ Port = [int]$env:RIOT_CLIENT_PORT; Token = $env:RIOT_CLIENT_AUTH_TOKEN }
    }

    # 2. Check lockfile paths
    foreach ($path in $LockfilePaths) {
        if (Test-Path $path) {
            Write-Log "Found lockfile at $path" "Green"
            $content = (Get-Content -Path $path -Raw).Trim()
            $parts = $content.Split(":")
            if ($parts.Count -ge 5) {
                return @{ Port = [int]$parts[2]; Token = $parts[3] }
            }
        }
    }

    # 3. Fallback to process inspection
    Write-Log "Lockfile not found. Inspecting running process..." "Yellow"
    try {
        $proc = Get-CimInstance Win32_Process -Filter "name = 'RiotClientUx.exe'" -ErrorAction Stop
        if ($proc.CommandLine -match "--app-port=(\d+)" -and $proc.CommandLine -match "--remoting-auth-token=([\w\-_]+)") {
            return @{ Port = [int]$Matches[1]; Token = $Matches[2] }
        }
    } catch {}

    return $null
}

function Get-LcuHeaders ($token) {
    $pair = "riot:$token"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    $base64 = [Convert]::ToBase64String($bytes)
    return @{
        "Authorization" = "Basic $base64"
        "Content-Type"  = "application/json"
    }
}

function Invoke-LcuRequest ($baseUrl, $token, $endpoint, $method = "GET", $body = $null) {
    $headers = Get-LcuHeaders $token
    $params = @{
        Uri             = "$baseUrl$endpoint"
        Method          = $method
        Headers         = $headers
        UseBasicParsing = $true
    }
    if ($body) {
        $params["Body"] = ($body | ConvertTo-Json -Depth 5 -Compress)
    }
    try {
        $res = Invoke-WebRequest @params
        if ($res.Content) { return ($res.Content | ConvertFrom-Json) }
    } catch {}
    return $null
}

function Get-LcuPlayerSession ($baseUrl, $token) {
    return Invoke-LcuRequest $baseUrl $token "/chat/v1/session"
}

function Get-LcuMessages ($baseUrl, $token) {
    $res = Invoke-LcuRequest $baseUrl $token "/chat/v6/messages"
    if ($res -is [PSCustomObject] -and $res.messages) { return $res.messages }
    if ($res -is [Array]) { return $res }
    return @()
}

function Send-LcuMessage ($baseUrl, $token, $cid, $message) {
    $body = @{ cid = $cid; message = $message; type = "chat" }
    $res = Invoke-LcuRequest $baseUrl $token "/chat/v6/messages" "POST" $body
    Write-Log " -> Message sent to chat ($cid)" "Green"
}

function Test-AntiSpam ($cid) {
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000.0
    
    if ($global:LastSentTime.ContainsKey($cid)) {
        if (($now - $global:LastSentTime[$cid]) -lt $global:COOLDOWN_PER_CHAT_SECONDS) {
            Write-Log "  [ANTI-SPAM] Cooldown active for chat" "Yellow"
            return $false
        }
    }

    # Clean old global entries
    $cutoff = $now - 10.0
    $global:GlobalSendHistory = [System.Collections.Generic.List[double]]($global:GlobalSendHistory | Where-Object { $_ -gt $cutoff })

    if ($global:GlobalSendHistory.Count -ge $global:GLOBAL_MAX_RESPONSES_PER_10S) {
        Write-Log "  [ANTI-SPAM] Global rate limit hit" "Yellow"
        return $false
    }

    $global:LastSentTime[$cid] = $now
    $global:GlobalSendHistory.Add($now)
    return $true
}

function Get-LlmResponse ($userMessage, $friendName) {
    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $global:LLM_API_KEY"
    }

    $prompt = "$global:CHATBOT_SYSTEM_PROMPT`nYou are currently chatting with $friendName."

    $payload = @{
        model       = $global:LLM_MODEL
        messages    = @(
            @{ role = "system"; content = $prompt },
            @{ role = "user"; content = $userMessage }
        )
        max_tokens  = 250
        temperature = 0.7
    } | ConvertTo-Json -Depth 5

    try {
        $uri = "$($global:LLM_BASE_URL.TrimEnd('/'))/chat/completions"
        $res = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $payload -TimeoutSec 30
        $text = $res.choices[0].message.content
        if ($text) { return $text.Trim() }
    } catch {
        Write-Log "  [LLM Error] $($_.Exception.Message)" "Red"
    }

    return ($global:DEFAULT_FALLBACKS | Get-Random)
}

# ===================================================================
# Main Entrypoint
# ===================================================================

Write-Host "===========================================================" -ForegroundColor Green
Write-Host "  maokAI CHATBOT (PowerShell Edition)" -ForegroundColor Green
Write-Host "  Target LLM: $global:LLM_BASE_URL" -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green

$creds = Read-Lockfile
if (-not $creds) {
    Write-Log "Unable to locate Riot Client credentials! Ensure the client is running." "Red"
    exit 1
}

$baseUrl = "https://127.0.0.1:$($creds.Port)"
Write-Log "Connected to Riot LCU API at $baseUrl" "Green"

$session = Get-LcuPlayerSession $baseUrl $creds.Token
$myPuuid = if ($session) { $session.puuid } else { "" }
$myName  = if ($session) { $session.game_name } else { "Player" }
Write-Log "Logged in as: $myName" "Cyan"

# Track seen messages
$seenIds = [System.Collections.Generic.HashSet[string]]::new()
$initialMsgs = Get-LcuMessages $baseUrl $creds.Token
foreach ($m in $initialMsgs) {
    $mid = if ($m.mid) { $m.mid } else { $m.id }
    if ($mid) { [void]$seenIds.Add($mid) }
}
Write-Log "Ignored $($seenIds.Count) historical messages" "DarkGray"

Write-Log "`n=== Message Listener Active ===" "Bold"

while ($true) {
    try {
        $messages = Get-LcuMessages $baseUrl $creds.Token
        foreach ($msg in $messages) {
            $mid = if ($msg.mid) { $msg.mid } else { $msg.id }
            if ($mid -and $seenIds.Contains($mid)) { continue }
            if ($mid) { [void]$seenIds.Add($mid) }

            $senderId = if ($msg.pid) { $msg.pid } else { $msg.puuid }
            $body = if ($msg.body) { $msg.body } else { $msg.message }
            $cid = $msg.cid

            if ($senderId -eq $myPuuid) { continue }
            if (-not $body -or $body.Trim() -eq "") { continue }

            Write-Log " << Received message: '$body'" "Cyan"

            $reply = Get-LlmResponse $body "Friend"

            if (Test-AntiSpam $cid) {
                Write-Log " >> maokAI: '$reply'" "Green"
                Send-LcuMessage $baseUrl $creds.Token $cid $reply
            }
        }
    } catch {}

    Start-Sleep -Seconds 2
}
