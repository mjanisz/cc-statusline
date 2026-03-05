#!/usr/bin/env bash
# cc-statusline — 3-line status display for Claude Code
# https://github.com/mjanisz/cc-statusline
#
# Shows: model, context window, git branch, thinking indicator,
#        5-hour + 7-day rate limit bars with reset countdowns.
# Handles OAuth token refresh on 401 and falls back to stale cache.

set -uo pipefail

# ── Colors ──────────────────────────────────────────────────────────────
RST='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
WHITE='\033[37m'
BRIGHT_WHITE='\033[97m'

# ── Read stdin JSON ─────────────────────────────────────────────────────
INPUT=$(cat)

# ── Git branch ─────────────────────────────────────────────────────────
GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "")

MODEL=$(echo "$INPUT" | jq -r '.model.display_name // .model.id // "unknown"' 2>/dev/null)
CTX_SIZE=$(echo "$INPUT" | jq -r '.context_window.context_window_size // 0' 2>/dev/null)
CTX_USED=$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
CTX_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null)

# Check for extended thinking
HAS_THINKING=$(echo "$INPUT" | jq -r '
  if .model.extended_thinking == true then "On"
  elif .context_window.thinking_tokens // 0 > 0 then "On"
  else "On"
  end' 2>/dev/null)
# Default to "On" for Opus models since they typically use thinking
if [[ "$MODEL" == *"Opus"* ]] || [[ "$MODEL" == *"opus"* ]]; then
  HAS_THINKING="On"
fi

# ── Format numbers ──────────────────────────────────────────────────────
format_k() {
  local n=$1
  if (( n >= 1000 )); then
    echo "$((n / 1000))k"
  else
    echo "$n"
  fi
}

CTX_USED_K=$(format_k "$CTX_USED")
CTX_SIZE_K=$(format_k "$CTX_SIZE")

# ── Usage API (cached 120s) ────────────────────────────────────────────
CACHE_FILE="/tmp/claude-statusline-usage.json"
CACHE_TTL=120
USAGE_JSON=""

get_access_token() {
  # macOS: read from Keychain
  if command -v security &>/dev/null; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken' 2>/dev/null
    return
  fi
  # Linux fallback: read from credentials file
  if [[ -f "$HOME/.claude/.credentials.json" ]]; then
    jq -r '.claudeAiOauth.accessToken' "$HOME/.claude/.credentials.json" 2>/dev/null
  fi
}

refresh_token() {
  local refresh
  if command -v security &>/dev/null; then
    refresh=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.refreshToken' 2>/dev/null) || return 1
  elif [[ -f "$HOME/.claude/.credentials.json" ]]; then
    refresh=$(jq -r '.claudeAiOauth.refreshToken' "$HOME/.claude/.credentials.json" 2>/dev/null) || return 1
  fi
  [[ -z "$refresh" || "$refresh" == "null" ]] && return 1

  local resp
  resp=$(curl -s --max-time 5 -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$refresh\"}" \
    "https://console.anthropic.com/v1/oauth/token" 2>/dev/null) || return 1

  local new_token
  new_token=$(echo "$resp" | jq -r '.access_token // empty' 2>/dev/null)
  [[ -z "$new_token" ]] && return 1
  echo "$new_token"
}

try_fetch_with_token() {
  local token=$1
  [[ -z "$token" || "$token" == "null" ]] && return 1

  local response http_code body
  response=$(curl -s --max-time 5 -w '\n%{http_code}' \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Accept: application/json" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "200" ]]; then
    echo "$body" | jq -e '.five_hour' >/dev/null 2>&1 || return 1
    echo "$body" > "$CACHE_FILE"
    echo "$body"
    return 0
  fi

  # Return special exit code 2 for 401 (token expired)
  [[ "$http_code" == "401" ]] && return 2
  return 1
}

fetch_usage() {
  local token
  token=$(get_access_token) || return 1

  try_fetch_with_token "$token"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    return 0
  elif [[ $rc -eq 2 ]]; then
    # Token expired — attempt refresh and retry
    local new_token
    new_token=$(refresh_token) || return 1
    try_fetch_with_token "$new_token"
    return $?
  fi

  return 1
}

# Check cache
if [[ -f "$CACHE_FILE" ]]; then
  CACHE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
  if (( CACHE_AGE < CACHE_TTL )); then
    USAGE_JSON=$(cat "$CACHE_FILE" 2>/dev/null)
  fi
fi

# Fetch if no cache
if [[ -z "$USAGE_JSON" ]]; then
  USAGE_JSON=$(fetch_usage 2>/dev/null) || USAGE_JSON=""
fi

# Stale cache fallback — show old data rather than nothing
if [[ -z "$USAGE_JSON" && -f "$CACHE_FILE" ]]; then
  USAGE_JSON=$(cat "$CACHE_FILE" 2>/dev/null)
fi

# ── Parse usage data ───────────────────────────────────────────────────
CURRENT_PCT=0
WEEKLY_PCT=0
CURRENT_RESET=""
WEEKLY_RESET=""
HAS_USAGE=false

if [[ -n "$USAGE_JSON" ]]; then
  CURRENT_PCT=$(echo "$USAGE_JSON" | jq -r '.five_hour.utilization // 0 | floor' 2>/dev/null)
  WEEKLY_PCT=$(echo "$USAGE_JSON" | jq -r '.seven_day.utilization // 0 | floor' 2>/dev/null)

  CURRENT_RESET=$(echo "$USAGE_JSON" | jq -r '.five_hour.resets_at // ""' 2>/dev/null)
  WEEKLY_RESET=$(echo "$USAGE_JSON" | jq -r '.seven_day.resets_at // ""' 2>/dev/null)

  if [[ "$CURRENT_PCT" != "0" ]] || [[ "$WEEKLY_PCT" != "0" ]]; then
    HAS_USAGE=true
  fi
fi

# ── Build usage bar ────────────────────────────────────────────────────
make_bar() {
  local pct=$1
  local color=$2
  local filled=$(( (pct + 5) / 10 ))  # round to nearest
  (( filled > 10 )) && filled=10
  (( filled < 0 )) && filled=0
  local empty=$((10 - filled))

  local bar=""
  for ((i=0; i<filled; i++)); do bar+="${color}●${RST}"; done
  for ((i=0; i<empty; i++)); do bar+="${DIM}○${RST}"; done
  echo "$bar"
}

# ── Format reset time ──────────────────────────────────────────────────
format_reset_countdown() {
  local iso=$1
  [[ -z "$iso" || "$iso" == "null" ]] && return

  local clean="${iso%%.*}"
  local tz_part=""
  if [[ "$iso" == *"+"* ]]; then
    tz_part="+${iso##*+}"
  elif [[ "$iso" == *"Z"* ]]; then
    tz_part="Z"
  fi
  [[ "$clean" != *"+"* && "$clean" != *"Z"* ]] && clean="${clean}${tz_part}"

  python3 -c "
from datetime import datetime, timezone
import sys
try:
    dt = datetime.fromisoformat(sys.argv[1])
    now = datetime.now(timezone.utc)
    diff = int((dt - now).total_seconds())
    if diff <= 0:
        print('now')
    elif diff < 60:
        print(f'in {diff} sec')
    elif diff < 3600:
        print(f'in {diff // 60} min')
    else:
        h, m = diff // 3600, (diff % 3600) // 60
        if m == 0:
            print(f'in {h} hr')
        else:
            print(f'in {h} hr {m} min')
except Exception:
    print(sys.argv[1][11:16])
" "$clean" 2>/dev/null || echo "${iso:11:5}"
}

format_reset_with_day() {
  local iso=$1
  [[ -z "$iso" || "$iso" == "null" ]] && return

  local clean="${iso%%.*}"
  local tz_part=""
  if [[ "$iso" == *"+"* ]]; then
    tz_part="+${iso##*+}"
  elif [[ "$iso" == *"Z"* ]]; then
    tz_part="Z"
  fi
  [[ "$clean" != *"+"* && "$clean" != *"Z"* ]] && clean="${clean}${tz_part}"

  python3 -c "
from datetime import datetime
import sys
try:
    iso = sys.argv[1]
    dt = datetime.fromisoformat(iso)
    local = dt.astimezone()
    day = local.strftime('%a')
    time = local.strftime('%-I:%M').lower() + local.strftime('%p').lower()
    print(f'{day} {time}')
except Exception:
    print(iso[11:16])
" "$clean" 2>/dev/null || echo "${iso:11:5}"
}

# ── Thinking label ──────────────────────────────────────────────────────
if [[ "$HAS_THINKING" == "On" ]]; then
  THINKING_LABEL="${BRIGHT_WHITE}${BOLD}thinking: On${RST}"
else
  THINKING_LABEL="${DIM}thinking: Off${RST}"
fi

# ── Line 1: Model | context | thinking ─────────────────────────────────
LINE1="${GREEN}${BOLD}${MODEL}${RST}"
LINE1+=" ${DIM}|${RST} "
LINE1+="${BOLD}${WHITE}${CTX_USED_K} / ${CTX_SIZE_K}${RST}"
LINE1+=" ${DIM}|${RST} "
LINE1+="${YELLOW}${CTX_PCT}% used${RST}"
if [[ -n "$GIT_BRANCH" ]]; then
  LINE1+=" ${DIM}|${RST} "
  LINE1+="${RED}git:(${RST}${CYAN}${GIT_BRANCH}${RST}${RED})${RST}"
fi
LINE1+=" ${DIM}|${RST} "
LINE1+="${THINKING_LABEL}"

# ── Line 2: Usage bars ─────────────────────────────────────────────────
if $HAS_USAGE; then
  CURRENT_BAR=$(make_bar "$CURRENT_PCT" "$YELLOW")
  WEEKLY_BAR=$(make_bar "$WEEKLY_PCT" "$GREEN")

  LINE2="${WHITE}current:${RST} ${CURRENT_BAR} ${WHITE}${CURRENT_PCT}%${RST}"
  LINE2+=" ${DIM}|${RST} "
  LINE2+="${WHITE}weekly:${RST} ${WEEKLY_BAR} ${WHITE}${WEEKLY_PCT}%${RST}"
else
  LINE2="${WHITE}current:${RST} ${DIM}○○○○○○○○○○${RST} ${DIM}--${RST}"
  LINE2+=" ${DIM}|${RST} "
  LINE2+="${WHITE}weekly:${RST} ${DIM}○○○○○○○○○○${RST} ${DIM}--${RST}"
fi

# ── Line 3: Reset times (right-aligned under bars) ─────────────────────
if $HAS_USAGE && { [[ -n "$CURRENT_RESET" ]] || [[ -n "$WEEKLY_RESET" ]]; }; then
  CURRENT_RESET_FMT=$(format_reset_countdown "$CURRENT_RESET")
  WEEKLY_RESET_FMT=$(format_reset_with_day "$WEEKLY_RESET")

  # Align reset texts under their respective bars
  WEEKLY_COL=$((9 + 10 + 1 + ${#CURRENT_PCT} + 1 + 3 + 8))

  RESET1=""
  if [[ -n "$CURRENT_RESET_FMT" ]]; then
    RESET1="resets ${CURRENT_RESET_FMT}"
  fi

  RESET2=""
  if [[ -n "$WEEKLY_RESET_FMT" ]]; then
    RESET2="resets ${WEEKLY_RESET_FMT}"
  fi

  # Right-align RESET1 to end at the "%" of current, RESET2 to end at "%" of weekly
  CURRENT_END=$((9 + 10 + 1 + ${#CURRENT_PCT} + 1))
  RESET1_LEN=${#RESET1}
  RESET1_PAD=$(( CURRENT_END - RESET1_LEN ))
  (( RESET1_PAD < 0 )) && RESET1_PAD=0
  LEADING=$(printf '%*s' "$RESET1_PAD" '')

  WEEKLY_END=$(( CURRENT_END + 3 + 8 + 10 + 1 + ${#WEEKLY_PCT} + 1 ))
  USED=$(( RESET1_PAD + RESET1_LEN ))
  RESET2_LEN=${#RESET2}
  GAP_NEEDED=$(( WEEKLY_END - USED - RESET2_LEN ))
  (( GAP_NEEDED < 2 )) && GAP_NEEDED=2
  GAP=$(printf '%*s' "$GAP_NEEDED" '')

  LINE3="${DIM}${LEADING}${RESET1}${GAP}${RESET2}${RST}"
else
  LINE3=""
fi

# ── Output ──────────────────────────────────────────────────────────────
echo -e "$LINE1"
echo -e "$LINE2"
[[ -n "$LINE3" ]] && echo -e "$LINE3"
