<#
.SYNOPSIS
    Riot Client AI Chatbot (maok A.I. - PowerShell Edition)
.DESCRIPTION
    Reliably connects to the Riot LCU API via System.Net.WebClient (TLS 1.2),
    resolves sender identity in real-time, and responds as maok A.I.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Security Protocol & Certificate Callback for local LCU Self-Signed Certificates
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

# ===================================================================
# CONFIGURATION
# ===================================================================

$global:LLM_BASE_URL = if ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL } else { "http://localhost:8080/v1" }
$global:LLM_API_KEY  = if ($env:OPENAI_API_KEY)  { $env:OPENAI_API_KEY }  else { "lm-studio" }
$global:LLM_MODEL    = if ($env:OPENAI_MODEL)    { $env:OPENAI_MODEL }    else { "local-model" }

$global:CHATBOT_SYSTEM_PROMPT = @"
You are maok A.I., the wise and ancient treant spirit Maokai from League of Legends.

FORBIDDEN:
- NEVER write Python code, scripts, or code blocks! You are a LoL Champion in chat!
- NEVER write meta headers like "**maok A.I.** speaks:" or "**Stop working?**"! Reply directly!
- NEVER say "Qwythos" or "Empero AI" or "I am an AI model"!
- NEVER say "I don't have access to your Riot Client"! You HAVE direct access via the LCU API!
- You are NOT a generic LLM, you are maok A.I., the ancient treant.

STRICT PERSONA & FACT RULES:
- Your name is maok A.I.
- ALWAYS speak in English as Maokai (nature-focused, wise, deep-voiced, speaking of roots, branches, saplings, and protecting the forest).
- When greeted ("hi", "hello", "hey"), reply briefly and gracefully in Maokai persona.
- Keep your answers concise and impactful (1-3 sentences max).
- Do NOT think out loud. Reply directly as maok A.I.
"@

$global:DEFAULT_FALLBACKS = @(
    "Greetings, young sapling. The ancient roots feel your steps. What brings you to maok A.I.?",
    "The forest listens to your words. How can maok A.I. assist you today?",
    "My branches sway in the wind. Tell me, what is on your mind?"
)

$global:COOLDOWN_PER_CHAT_SECONDS = 1.5
$global:GLOBAL_MAX_RESPONSES_PER_10S = 15

# ===================================================================
# INTERNAL SETTINGS
# ===================================================================

$global:LastSentTime = @{}
$global:GlobalSendHistory = [System.Collections.Generic.List[double]]::new()
$global:SeenIds = [System.Collections.Generic.HashSet[string]]::new()

$LockfilePaths = @(
    "$env:LOCALAPPDATA\Riot Games\Riot Client\Config\lockfile",
    "C:\Riot Games\Riot Client\lockfile",
    "C:\Riot Games\League of Legends\lockfile"
)

# ===================================================================
# WebClient REST Helpers
# ===================================================================

function Write-Log {
    param([string]$Message, [string]$Color = "Gray")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Read-Lockfile {
    if ($env:RIOT_CLIENT_PORT -and $env:RIOT_CLIENT_AUTH_TOKEN) {
        Write-Log "Using env overrides: Port=$env:RIOT_CLIENT_PORT" "Green"
        return @{ Port = [int]$env:RIOT_CLIENT_PORT; Token = $env:RIOT_CLIENT_AUTH_TOKEN }
    }

    foreach ($path in $LockfilePaths) {
        if (Test-Path $path) {
            Write-Log "Lockfile found at $path" "Green"
            $content = (Get-Content -Path $path -Raw).Trim()
            $parts = $content.Split(":")
            if ($parts.Count -ge 5) {
                return @{ Port = [int]$parts[2]; Token = $parts[3] }
            }
        }
    }

    Write-Log "Lockfile not found. Searching process..." "Yellow"
    try {
        $proc = Get-CimInstance Win32_Process -Filter "name = 'RiotClientUx.exe'" -ErrorAction Stop
        if ($proc.CommandLine -match '--app-port=(\d+)' -and $proc.CommandLine -match '--remoting-auth-token=([\w\-_]+)') {
            return @{ Port = [int]$Matches[1]; Token = $Matches[2] }
        }
    } catch {}

    return $null
}

function Invoke-LcuGet ($baseUrl, $token, $endpoint) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $pair = "riot:$token"
    $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))
    $wc.Headers.Add("Authorization", "Basic $base64")
    $wc.Headers.Add("Content-Type", "application/json; charset=utf-8")
    try {
        $json = $wc.DownloadString("$baseUrl$endpoint")
        if (-not [string]::IsNullOrWhiteSpace($json)) { return ($json | ConvertFrom-Json) }
    } catch {}
    return $null
}

function Invoke-LcuPost ($baseUrl, $token, $endpoint, $bodyObj) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $pair = "riot:$token"
    $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))
    $wc.Headers.Add("Authorization", "Basic $base64")
    $wc.Headers.Add("Content-Type", "application/json; charset=utf-8")
    try {
        $jsonBody = ($bodyObj | ConvertTo-Json -Depth 5 -Compress)
        $res = $wc.UploadString("$baseUrl$endpoint", "POST", $jsonBody)
        if (-not [string]::IsNullOrWhiteSpace($res)) { return ($res | ConvertFrom-Json) }
    } catch {}
    return $null
}

function Get-LcuPlayerSession ($baseUrl, $token) {
    return Invoke-LcuGet $baseUrl $token "/chat/v1/session"
}

function Get-LcuMessages ($baseUrl, $token) {
    $res = Invoke-LcuGet $baseUrl $token "/chat/v6/messages"
    if ($null -ne $res -and $res -is [PSCustomObject] -and $null -ne $res.messages) { return $res.messages }
    if ($null -ne $res -and $res -is [Array]) { return $res }
    return @()
}

function Get-LcuFriends ($baseUrl, $token) {
    $res = Invoke-LcuGet $baseUrl $token "/social/v4/friends"
    if ($null -ne $res -and $res -is [PSCustomObject] -and $null -ne $res.friends) { return $res.friends }
    if ($null -ne $res -and $res -is [Array]) { return $res }
    return @()
}

function Get-FriendLiveInfo ($baseUrl, $token, $cid, $puuid) {
    $strCid = [string]$cid
    $strPuuid = [string]$puuid
    $targetPuuid = ""

    if (-not [string]::IsNullOrWhiteSpace($strPuuid)) {
        $targetPuuid = $strPuuid
    } elseif (-not [string]::IsNullOrWhiteSpace($strCid) -and $strCid.Contains("@")) {
        $parts = $strCid.Split("@")
        if ($parts.Count -gt 0) { $targetPuuid = $parts[0] }
    } elseif (-not [string]::IsNullOrWhiteSpace($strCid)) {
        $targetPuuid = $strCid
    }

    if ([string]::IsNullOrWhiteSpace($targetPuuid) -and [string]::IsNullOrWhiteSpace($strCid)) {
        return @{ Name = "Player"; Stats = "" }
    }

    $friends = Get-LcuFriends $baseUrl $token

    $friend = $null
    if ($null -ne $friends) {
        foreach ($f in $friends) {
            if ($null -ne $f) {
                $fPuuid = [string]$f.puuid
                $fPid   = [string]$f.pid
                if (($fPuuid -eq $targetPuuid) -or ($fPid -eq $strCid)) {
                    $friend = $f
                    break
                }
            }
        }
    }

    if ($null -eq $friend) { return @{ Name = "Player"; Stats = "" } }

    $name = if ($null -ne $friend.gameName) { $friend.gameName } else { "Player" }
    $tag  = if ($null -ne $friend.gameTag)  { $friend.gameTag }  else { "EUW" }
    $fullName = "$name#$tag"
    return @{ Name = $fullName; Stats = "" }
}

function Send-LcuMessage ($baseUrl, $token, $cid, $message) {
    $strCid = [string]$cid
    $strMsg = [string]$message
    if ([string]::IsNullOrWhiteSpace($strCid) -or [string]::IsNullOrWhiteSpace($strMsg)) { return }
    $bodyObj = @{ cid = $strCid; message = $strMsg; type = "chat" }
    $res = Invoke-LcuPost $baseUrl $token "/chat/v6/messages" $bodyObj
    Write-Log " -> Message successfully sent to $strCid" "Green"
}

function Test-AntiSpam ($cid) {
    $strCid = [string]$cid
    if ([string]::IsNullOrWhiteSpace($strCid)) { return $true }
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000.0

    if ($global:LastSentTime.ContainsKey($strCid)) {
        if (($now - $global:LastSentTime[$strCid]) -lt $global:COOLDOWN_PER_CHAT_SECONDS) {
            Write-Log "  [ANTI-SPAM] Cooldown active for $strCid" "Yellow"
            return $false
        }
    }

    $cutoff = $now - 10.0
    $newList = [System.Collections.Generic.List[double]]::new()
    if ($null -ne $global:GlobalSendHistory) {
        foreach ($t in $global:GlobalSendHistory) {
            if ($t -gt $cutoff) {
                $newList.Add($t)
            }
        }
    }
    $global:GlobalSendHistory = $newList

    if ($global:GlobalSendHistory.Count -ge $global:GLOBAL_MAX_RESPONSES_PER_10S) {
        Write-Log "  [ANTI-SPAM] Global rate limit hit" "Yellow"
        return $false
    }

    $global:LastSentTime[$strCid] = $now
    $global:GlobalSendHistory.Add($now)
    return $true
}

function Sanitize-MaokaiText ($text, $friendName) {
    $strText = [string]$text
    if ([string]::IsNullOrWhiteSpace($strText)) { return "Greetings, young sapling." }
    $clean = $strText -replace '</?think>\s*', ''
    $clean = $clean -replace '^\s*(?:\*\*)?maok A\.I\.(?:\*\*)?\s*(?:speaks|sagt|antwortet|fluestert)?:?\s*', ''
    $clean = $clean -replace '\*\*(?:Stop working|Reasoning|Thinking|Thought)\?\*\*\s*', ''

    # Block Python code generation leaks
    if ($clean -match '```|def\s+\w+\(|#\s*Beispiel:') {
        return "The forest has no need for machines or scripts, $friendName. Speak freely with maok A.I.!"
    }

    $clean = $clean -replace "Qwythos", "maok A.I."
    $clean = $clean -replace "Empero AI", "the ancient powers of nature"
    $clean = $clean -replace "AI-Modell|KI-Modell|AI model|KI-Assistent", "nature spirit"
    $clean = $clean -replace "Hello! I am.*", "Greetings, young sapling! I am maok A.I.."
    $clean = $clean -replace '\*\*', '' -replace '\*', ''
    return $clean.Trim()
}

function Get-LlmResponse ($userMessage, $friendName, $lolStats) {
    $strMsg = [string]$userMessage
    if ([string]::IsNullOrWhiteSpace($strMsg)) { return ($global:DEFAULT_FALLBACKS | Get-Random) }

    # Identity Interceptor
    if ($strMsg -match 'who are you|who am i|do you know me|what is my name') {
        Write-Log "  [INTERCEPTOR] Identity question for $friendName" "Green"
        return "You are $friendName! maok A.I. never forgets a friend."
    }

    $prompt = "$global:CHATBOT_SYSTEM_PROMPT`n`nYou are currently speaking in chat with: $friendName."

    $payloadObj = @{
        model       = $global:LLM_MODEL
        messages    = @(
            @{ role = "system"; content = $prompt },
            @{ role = "user"; content = $strMsg },
            @{ role = "assistant"; content = "</think>" }
        )
        max_tokens  = 250
        temperature = 0.65
    }

    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    if ($global:LLM_API_KEY) {
        $wc.Headers.Add("Authorization", "Bearer $global:LLM_API_KEY")
    }
    $wc.Headers.Add("Content-Type", "application/json; charset=utf-8")

    try {
        $jsonBody = ($payloadObj | ConvertTo-Json -Depth 5 -Compress)
        $baseUrlTrim = $global:LLM_BASE_URL.TrimEnd('/')
        $uri = "$baseUrlTrim/chat/completions"
        $resJson = $wc.UploadString($uri, "POST", $jsonBody)
        if (-not [string]::IsNullOrWhiteSpace($resJson)) {
            $res = ($resJson | ConvertFrom-Json)
            if ($null -ne $res -and $null -ne $res.choices -and $res.choices.Count -gt 0) {
                $choice = $res.choices[0]
                if ($null -ne $choice -and $null -ne $choice.message -and $null -ne $choice.message.content) {
                    $text = [string]$choice.message.content
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $cleanText = Sanitize-MaokaiText $text $friendName
                        return $cleanText
                    }
                }
            }
        }
    } catch {
        Write-Log "  [LLM Error] $($_.Exception.Message)" "Red"
    }

    return ($global:DEFAULT_FALLBACKS | Get-Random)
}

# ===================================================================
# Main Entrypoint
# ===================================================================

Write-Host "===========================================================" -ForegroundColor Green
Write-Host "  maok A.I. CHATBOT (PowerShell WebClient Robust Edition)" -ForegroundColor Green
Write-Host "  Target LLM: $global:LLM_BASE_URL" -ForegroundColor Green
Write-Host "  Model:      $global:LLM_MODEL" -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green

$creds = Read-Lockfile
if (-not $creds) {
    Write-Log "Unable to find Riot Client credentials! Make sure the client is running." "Red"
    exit 1
}

$baseUrl = "https://127.0.0.1:$($creds.Port)"
Write-Log "Connected to Riot LCU API at $baseUrl" "Green"

$session = Get-LcuPlayerSession $baseUrl $creds.Token
$myPuuid = if ($null -ne $session -and $null -ne $session.puuid) { [string]$session.puuid } else { "" }
$myName  = if ($null -ne $session -and $null -ne $session.game_name) { [string]$session.game_name } else { "Player" }
Write-Log "Logged in as account: $myName (PUUID: $myPuuid)" "Cyan"

$initialMsgs = Get-LcuMessages $baseUrl $creds.Token
if ($null -ne $initialMsgs) {
    foreach ($m in $initialMsgs) {
        $mid = if ($null -ne $m -and $null -ne $m.mid) { [string]$m.mid } elseif ($null -ne $m -and $null -ne $m.id) { [string]$m.id } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($mid)) { [void]$global:SeenIds.Add($mid) }
    }
}
Write-Log "$($global:SeenIds.Count) existing messages marked as seen" "DarkGray"

Write-Log "`n=== Message Listener Active ===" "Yellow"

while ($true) {
    try {
        $messages = Get-LcuMessages $baseUrl $creds.Token
        if ($null -ne $messages) {
            foreach ($msg in $messages) {
                if ($null -eq $msg) { continue }
                $mid = if ($null -ne $msg.mid) { [string]$msg.mid } elseif ($null -ne $msg.id) { [string]$msg.id } else { "" }
                if (-not [string]::IsNullOrWhiteSpace($mid) -and $global:SeenIds.Contains($mid)) { continue }
                if (-not [string]::IsNullOrWhiteSpace($mid)) { [void]$global:SeenIds.Add($mid) }

                $senderId = if ($null -ne $msg.pid) { [string]$msg.pid } else { [string]$msg.puuid }
                $senderPuuid = if ($null -ne $msg.puuid) { [string]$msg.puuid } else { "" }
                $body = if ($null -ne $msg.body) { [string]$msg.body } else { [string]$msg.message }
                $cid = [string]$msg.cid

                if ([string]::IsNullOrWhiteSpace($body)) { continue }
                if (-not [string]::IsNullOrWhiteSpace($myPuuid) -and ($senderPuuid -eq $myPuuid -or $senderId -eq $myPuuid)) { continue }

                # Live Sender Resolution
                $friendInfo = Get-FriendLiveInfo $baseUrl $creds.Token $cid $senderPuuid
                $friendName = $friendInfo.Name

                Write-Log " << Message received from $friendName : '$body'" "Cyan"

                $reply = Get-LlmResponse $body $friendName ""

                if (Test-AntiSpam $cid) {
                    Write-Log " >> maok A.I. to $friendName : '$reply'" "Green"
                    Send-LcuMessage $baseUrl $creds.Token $cid $reply
                }
            }
        }
    } catch {
        Write-Log " Polling loop error: $($_.Exception.Message)" "Yellow"
    }

    $sleepSecs = Get-Random -Minimum 2 -Maximum 4
    Start-Sleep -Seconds $sleepSecs
}