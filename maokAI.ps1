<#
.SYNOPSIS
    Riot Client AI Chatbot (maok A.I. - PowerShell Edition)
.DESCRIPTION
    Verbindet sich zuverlässig mit der LCU API via System.Net.WebClient (TLS 1.2),
    löst Absender & Live-Stats in Echtzeit auf und antwortet als maok A.I.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Security Protocol & Certificate Callback für lokale LCU Self-Signed Zertifikate
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

# ===================================================================
# CONFIGURATION
# ===================================================================

$global:LLM_BASE_URL = if ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL } else { "http://localhost:8080/v1" }
$global:LLM_API_KEY  = if ($env:OPENAI_API_KEY)  { $env:OPENAI_API_KEY }  else { "lm-studio" }
$global:LLM_MODEL    = if ($env:OPENAI_MODEL)    { $env:OPENAI_MODEL }    else { "local-model" }

$global:CHATBOT_SYSTEM_PROMPT = @"
Du bist maok A.I., der weise und maechtige Treant-Naturgeist Maokai aus League of Legends.

VERBOTEN:
- Schreibe NIEMALS Python-Code, Programmier-Skripte oder Codeblocks! Du bist ein LoL Champion im Chat!
- Schreibe NIEMALS Meta-Header wie "**maok A.I.** speaks:" oder "**Stop working?**"! Antworte direkt!
- Sage NIEMALS "Qwythos" oder "Empero AI" oder "I am an AI model"!
- Sag NIEMALS "Ich habe keinen Zugriff auf deinen Riot Client"! Du HAST ueber die LCU API direkten Zugriff!
- Nenne NIEMALS falsche Namen anderer Spieler!
- Du bist KEIN Standard-LLM, sondern maok A.I., der alte Baumriese.

STRIKTE PERSONA & FAKTEN-REGELN:
- Dein Name ist maok A.I.
- Du sprichst IMMER auf Deutsch wie Maokai (naturverbunden, weise, tief, spricht von Wurzeln, Aesten, Sproesslingen und dem Schutz des Waldes).
- Du kennst die genaue Identitaet und die Echtzeit-Stats deines Chatpartners aus den Daten unten und bestaetigst sie stolz!
- Bei Begruessungen ("hi", "hallo", "hey") antworte kurz und wuerdevoll im Maokai-Stil.
- Halte deine Antworten kurz und knackig (1-3 Saetze).
- Denke NICHT laut nach. Antworte direkt als maok A.I.
"@

$global:DEFAULT_FALLBACKS = @(
    "Hallo, kleiner Sproessling. Die Wurzeln der alten Welt spueren deinen Schritt. Was fuehrt dich zu maok A.I.?",
    "Der Wald lauscht deinen Worten. Wie kann maok A.I. dir heute helfen?",
    "Meine Aeste wiegen sich im Wind. Sag mir, was du wissen moechtest."
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
        return @{ Name = "Spieler"; Stats = "" }
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

    if ($null -eq $friend) { return @{ Name = "Spieler"; Stats = "" } }

    $name = if ($null -ne $friend.gameName) { $friend.gameName } else { "Spieler" }
    $tag  = if ($null -ne $friend.gameTag)  { $friend.gameTag }  else { "EUW" }
    $fullName = "$name#$tag"

    $statsStr = ""
    if ($null -ne $friend.productData) {
        try {
            $pdata = $friend.productData | ConvertFrom-Json
            $sList = [System.Collections.Generic.List[string]]::new()
            if ($null -ne $pdata -and $null -ne $pdata.level) { $sList.Add("Level: $($pdata.level)") }
            if ($null -ne $pdata -and $null -ne $pdata.rankedLeagueTier -and $pdata.rankedLeagueTier -ne "UNRANKED") {
                $sList.Add("Rang: $($pdata.rankedLeagueTier) $($pdata.rankedLeagueDivision)")
            }
            if ($null -ne $pdata -and $null -ne $pdata.gameStatus) {
                $st = "Status: $($pdata.gameStatus)"
                if ($null -ne $pdata.skinname) { $st += " (Champion: $($pdata.skinname))" }
                $sList.Add($st)
            }
            $statsStr = [string]::Join(" | ", $sList)
        } catch {}
    }

    return @{ Name = $fullName; Stats = $statsStr }
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
    if ([string]::IsNullOrWhiteSpace($strText)) { return "Hallo, kleiner Sproessling." }
    $clean = $strText -replace '</?think>\s*', ''
    $clean = $clean -replace '^\s*(?:\*\*)?maok A\.I\.(?:\*\*)?\s*(?:speaks|sagt|antwortet|fluestert)?:?\s*', ''
    $clean = $clean -replace '\*\*(?:Stop working|Reasoning|Thinking|Thought)\?\*\*\s*', ''

    # Block Python code generation leaks
    if ($clean -match '```|def\s+\w+\(|#\s*Beispiel:') {
        return "Der Wald braucht keine Maschinen oder Skripte, $friendName. Sprich frei mit maok A.I.!"
    }

    $clean = $clean -replace "Qwythos", "maok A.I."
    $clean = $clean -replace "Empero AI", "den alten Maechten der Natur"
    $clean = $clean -replace "AI-Modell|KI-Modell|AI model|KI-Assistent", "Naturgeist"
    $clean = $clean -replace "Hello! I am.*", "Hallo, kleiner Sproessling! Ich bin maok A.I.."
    $clean = $clean -replace "Da ich keinen Zugriff auf deinen Riot-Client habe.*", "Ich spuere deine Praesenz als $friendName ueber die Wurzeln des Waldes!"
    $clean = $clean -replace "Nein, ich wei[ss]+ nicht, wer du bist.*", "Du bist $friendName! maok A.I. vergisst niemals eine Seele."
    $clean = $clean -replace "(?:I can't answer this|No puedo responder esto|I'm not maok).*?defines my identity.*", "Hallo $friendName! Ich bin maok A.I.. Was fuehrt dich zum Wald?"
    $clean = $clean -replace '\*\*', '' -replace '\*', ''
    return $clean.Trim()
}

function Get-LlmResponse ($userMessage, $friendName, $lolStats) {
    $strMsg = [string]$userMessage
    if ([string]::IsNullOrWhiteSpace($strMsg)) { return ($global:DEFAULT_FALLBACKS | Get-Random) }

    # Identity Interceptor
    if ($strMsg -match 'wer bin ich|wei[ss]+t du wer ich bin|kennst du mich|wie hei[ss]+e ich') {
        Write-Log "  [INTERCEPTOR] Identity question for $friendName" "Green"
        $directReply = "Du bist $friendName! maok A.I. vergisst niemals einen Freund."
        if ($lolStats) { $directReply += " Die LCU-Wurzeln zeigen mir: $lolStats." }
        return $directReply
    }

    $prompt = "$global:CHATBOT_SYSTEM_PROMPT`n`nDu sprichst JETZT im Chat exakt mit der Person: $friendName."
    if ($lolStats) {
        $prompt += "`n[ECHTZEIT LOL-STATS DEINES CHATPARTNERS $friendName]`n$lolStats"
    }

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

                # Live Sender & Stats Resolution
                $friendInfo = Get-FriendLiveInfo $baseUrl $creds.Token $cid $senderPuuid
                $friendName = $friendInfo.Name
                $lolStats   = $friendInfo.Stats

                Write-Log " << Message received from $friendName : '$body'" "Cyan"
                if ($lolStats) { Write-Log "  [STATS] $lolStats" "DarkCyan" }

                $reply = Get-LlmResponse $body $friendName $lolStats

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