#!/usr/bin/env pwsh
# cc-statusline — 3-line status display for Claude Code (PowerShell)
# https://github.com/mjanisz/cc-statusline
#
# Shows: model, context window, git branch, thinking indicator,
#        5-hour + 7-day rate limit bars with reset countdowns.

$ErrorActionPreference = 'SilentlyContinue'

# ── Colors (ANSI) ──────────────────────────────────────────────────────
$RST          = "`e[0m"
$BOLD         = "`e[1m"
$DIM          = "`e[2m"
$RED          = "`e[31m"
$GREEN        = "`e[32m"
$YELLOW       = "`e[33m"
$CYAN         = "`e[36m"
$WHITE        = "`e[37m"
$BRIGHT_WHITE = "`e[97m"

# ── Read stdin JSON ────────────────────────────────────────────────────
$inputText = @($input) -join "`n"
if ([string]::IsNullOrWhiteSpace($inputText)) {
    $inputText = '{}'
}

try {
    $json = $inputText | ConvertFrom-Json
} catch {
    $json = @{} | ConvertTo-Json | ConvertFrom-Json
}

# ── Git branch ─────────────────────────────────────────────────────────
$gitBranch = ''
try {
    $gitBranch = git symbolic-ref --short HEAD 2>$null
    if (-not $gitBranch) {
        $gitBranch = git rev-parse --short HEAD 2>$null
    }
} catch {}
if ($null -eq $gitBranch) { $gitBranch = '' }
$gitBranch = "$gitBranch".Trim()

# ── Parse context data ─────────────────────────────────────────────────
$model   = if ($json.model.display_name) { $json.model.display_name } elseif ($json.model.id) { $json.model.id } else { 'unknown' }
$ctxSize = if ($json.context_window.context_window_size) { [int]$json.context_window.context_window_size } else { 0 }
$ctxUsed = if ($json.context_window.total_input_tokens) { [int]$json.context_window.total_input_tokens } else { 0 }
$ctxPct  = if ($json.context_window.used_percentage) { [int]$json.context_window.used_percentage } else { 0 }

# Check for extended thinking
$hasThinking = 'On'
if ($model -match '(?i)opus') { $hasThinking = 'On' }

# ── Format numbers ─────────────────────────────────────────────────────
function Format-K([int]$n) {
    if ($n -ge 1000) { return "$([math]::Floor($n / 1000))k" }
    return "$n"
}

$ctxUsedK = Format-K $ctxUsed
$ctxSizeK = Format-K $ctxSize

# ── Usage API (cached 60s) ─────────────────────────────────────────────
$cacheDir  = Join-Path $env:TEMP 'claude'
$cacheFile = Join-Path $cacheDir 'statusline-usage-cache.json'
$cacheTTL  = 60
$usageJson = $null

function Get-OAuthToken {
    # Try credentials file first (cross-platform)
    $credFile = Join-Path $HOME '.claude' '.credentials.json'
    if (Test-Path $credFile) {
        try {
            $cred = Get-Content $credFile -Raw | ConvertFrom-Json
            $token = $cred.claudeAiOauth.accessToken
            if ($token -and $token -ne 'null') { return $token }
        } catch {}
    }
    # Windows: try Credential Manager
    if ($IsWindows) {
        try {
            $cred = cmdkey /list:Claude* 2>$null
            # Credential Manager doesn't easily expose passwords via cmdkey;
            # the credentials file is the primary method
        } catch {}
    }
    return $null
}

function Fetch-Usage {
    $token = Get-OAuthToken
    if (-not $token) { return $null }

    try {
        $headers = @{
            'Authorization'  = "Bearer $token"
            'anthropic-beta' = 'oauth-2025-04-20'
            'Accept'         = 'application/json'
        }
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' `
            -Headers $headers -TimeoutSec 5 -ErrorAction Stop

        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
        $resp | ConvertTo-Json -Depth 10 | Set-Content $cacheFile -Force
        return $resp
    } catch {
        return $null
    }
}

# Check cache
if (Test-Path $cacheFile) {
    $cacheAge = ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalSeconds
    if ($cacheAge -lt $cacheTTL) {
        try {
            $usageJson = Get-Content $cacheFile -Raw | ConvertFrom-Json
        } catch {}
    }
}

# Fetch if no cache
if (-not $usageJson) {
    $usageJson = Fetch-Usage
}

# ── Parse usage data ──────────────────────────────────────────────────
$currentPct   = 0
$weeklyPct    = 0
$currentReset = ''
$weeklyReset  = ''
$hasUsage     = $false

if ($usageJson) {
    $currentPct   = if ($usageJson.five_hour.utilization) { [math]::Floor([double]$usageJson.five_hour.utilization) } else { 0 }
    $weeklyPct    = if ($usageJson.seven_day.utilization) { [math]::Floor([double]$usageJson.seven_day.utilization) } else { 0 }
    $currentReset = if ($usageJson.five_hour.resets_at) { "$($usageJson.five_hour.resets_at)" } else { '' }
    $weeklyReset  = if ($usageJson.seven_day.resets_at) { "$($usageJson.seven_day.resets_at)" } else { '' }

    if ($currentPct -ne 0 -or $weeklyPct -ne 0) { $hasUsage = $true }
}

# ── Build usage bar ───────────────────────────────────────────────────
function Make-Bar([int]$pct, [string]$color) {
    $filled = [math]::Min(10, [math]::Max(0, [math]::Floor(($pct + 5) / 10)))
    $empty  = 10 - $filled

    $bar = ''
    for ($i = 0; $i -lt $filled; $i++) { $bar += "${color}`u{25CF}${RST}" }
    for ($i = 0; $i -lt $empty; $i++)  { $bar += "${DIM}`u{25CB}${RST}" }
    return $bar
}

# ── Format reset times ────────────────────────────────────────────────
function Format-ResetCountdown([string]$iso) {
    if ([string]::IsNullOrWhiteSpace($iso) -or $iso -eq 'null') { return '' }
    try {
        $dt   = [DateTimeOffset]::Parse($iso)
        $now  = [DateTimeOffset]::UtcNow
        $diff = [int]($dt - $now).TotalSeconds

        if ($diff -le 0)       { return 'now' }
        elseif ($diff -lt 60)  { return "in $diff sec" }
        elseif ($diff -lt 3600) { return "in $([math]::Floor($diff / 60)) min" }
        else {
            $h = [math]::Floor($diff / 3600)
            $m = [math]::Floor(($diff % 3600) / 60)
            if ($m -eq 0) { return "in $h hr" }
            return "in $h hr $m min"
        }
    } catch {
        return $iso.Substring(11, 5)
    }
}

function Format-ResetWithDay([string]$iso) {
    if ([string]::IsNullOrWhiteSpace($iso) -or $iso -eq 'null') { return '' }
    try {
        $dt    = [DateTimeOffset]::Parse($iso)
        $local = $dt.ToLocalTime()
        $day   = $local.ToString('ddd')
        $hour  = $local.ToString('h:mm').ToLower()
        $ampm  = $local.ToString('tt').ToLower()
        return "$day ${hour}${ampm}"
    } catch {
        return $iso.Substring(11, 5)
    }
}

# ── Thinking label ─────────────────────────────────────────────────────
if ($hasThinking -eq 'On') {
    $thinkingLabel = "${BRIGHT_WHITE}${BOLD}thinking: On${RST}"
} else {
    $thinkingLabel = "${DIM}thinking: Off${RST}"
}

# ── Line 1: Model | context | thinking ────────────────────────────────
$line1 = "${GREEN}${BOLD}${model}${RST}"
$line1 += " ${DIM}|${RST} "
$line1 += "${BOLD}${WHITE}${ctxUsedK} / ${ctxSizeK}${RST}"
$line1 += " ${DIM}|${RST} "
$line1 += "${YELLOW}${ctxPct}% used${RST}"
if ($gitBranch) {
    $line1 += " ${DIM}|${RST} "
    $line1 += "${RED}git:(${RST}${CYAN}${gitBranch}${RST}${RED})${RST}"
}
$line1 += " ${DIM}|${RST} "
$line1 += $thinkingLabel

# ── Line 2: Usage bars ────────────────────────────────────────────────
if ($hasUsage) {
    $currentBar = Make-Bar $currentPct $YELLOW
    $weeklyBar  = Make-Bar $weeklyPct $GREEN

    $line2 = "${WHITE}current:${RST} ${currentBar} ${WHITE}${currentPct}%${RST}"
    $line2 += " ${DIM}|${RST} "
    $line2 += "${WHITE}weekly:${RST} ${weeklyBar} ${WHITE}${weeklyPct}%${RST}"
} else {
    $empty10 = "${DIM}" + ("`u{25CB}" * 10) + "${RST}"
    $line2 = "${WHITE}current:${RST} ${empty10} ${DIM}--${RST}"
    $line2 += " ${DIM}|${RST} "
    $line2 += "${WHITE}weekly:${RST} ${empty10} ${DIM}--${RST}"
}

# ── Line 3: Reset times (right-aligned under bars) ────────────────────
$line3 = ''
if ($hasUsage -and ($currentReset -or $weeklyReset)) {
    $currentResetFmt = Format-ResetCountdown $currentReset
    $weeklyResetFmt  = Format-ResetWithDay $weeklyReset

    $reset1 = if ($currentResetFmt) { "resets $currentResetFmt" } else { '' }
    $reset2 = if ($weeklyResetFmt)  { "resets $weeklyResetFmt" }  else { '' }

    # Align reset texts under their respective bars
    $currentEnd = 9 + 10 + 1 + "$currentPct".Length + 1
    $reset1Len  = $reset1.Length
    $reset1Pad  = [math]::Max(0, $currentEnd - $reset1Len)
    $leading    = ' ' * $reset1Pad

    $weeklyEnd  = $currentEnd + 3 + 8 + 10 + 1 + "$weeklyPct".Length + 1
    $used       = $reset1Pad + $reset1Len
    $reset2Len  = $reset2.Length
    $gapNeeded  = [math]::Max(2, $weeklyEnd - $used - $reset2Len)
    $gap        = ' ' * $gapNeeded

    $line3 = "${DIM}${leading}${reset1}${gap}${reset2}${RST}"
}

# ── Output ─────────────────────────────────────────────────────────────
Write-Host $line1
Write-Host $line2
if ($line3) { Write-Host $line3 }
