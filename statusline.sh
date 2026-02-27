#!/usr/bin/env bash
# ~/.claude/statusline.sh — Custom statusline for Claude Code
# Reads JSON payload from stdin, outputs a single ANSI-coloured line.

# ─── Colour constants ────────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
GREY='\033[90m'
B_ORANGE='\033[1;38;5;208m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
SEP="${GREY} | ${RESET}"

# ─── Helpers ─────────────────────────────────────────────────────────────────
colour_gradient() {
  local val=$1
  if   [ "$val" -lt 50 ]; then echo -e '\033[1;32m'
  elif [ "$val" -lt 75 ]; then echo -e '\033[1;33m'
  elif [ "$val" -lt 90 ]; then echo -e '\033[1;38;5;208m'
  else                         echo -e '\033[1;31m'
  fi
}

get_val() { printf '%s' "$JSON" | jq -r "${1} // empty" 2>/dev/null; }

# context_bar <int 0-100> — returns a coloured block bar
context_bar() {
  local pct=$1 width=10 filled bar=""
  [ "$pct" -gt 100 ] && pct=100
  filled=$(( pct * width / 100 ))
  for i in $(seq 1 $width); do
    if [ "$i" -le "$filled" ]; then
      # Gradient: green -> yellow -> orange -> red across the bar
      local pos=$(( i * 100 / width ))
      if   [ "$pos" -le 40 ]; then bar="${bar}\033[32m█${RESET}"
      elif [ "$pos" -le 65 ]; then bar="${bar}\033[33m█${RESET}"
      elif [ "$pos" -le 85 ]; then bar="${bar}\033[38;5;208m█${RESET}"
      else                         bar="${bar}\033[31m█${RESET}"
      fi
    else
      bar="${bar}\033[90m░${RESET}"
    fi
  done
  echo -e "${bar}"
}

# ─── Read stdin ───────────────────────────────────────────────────────────────
JSON=$(cat)

# ─── Core fields ─────────────────────────────────────────────────────────────
MODEL=$(get_val '.model.display_name')
CWD=$(get_val '.workspace.current_dir')
CTX_PCT=$(get_val '.context_window.used_percentage')
DURATION_MS=$(get_val '.cost.total_duration_ms')
VIM_MODE=$(get_val '.vim.mode')
CACHE_READ=$(get_val '.context_window.current_usage.cache_read_input_tokens')
CACHE_CREATE=$(get_val '.context_window.current_usage.cache_creation_input_tokens')
LINES_ADD=$(get_val '.cost.total_lines_added')
LINES_REM=$(get_val '.cost.total_lines_removed')

# Derived values
DIR_NAME="${CWD##*[/\\]}"
CTX_INT=0
[ -n "$CTX_PCT" ] && CTX_INT=$(printf '%.0f' "$CTX_PCT" 2>/dev/null || echo 0)

# ─── Git info ─────────────────────────────────────────────────────────────────
GIT_BRANCH=""
GIT_DIRTY=""
GIT_AGE=""
if [ -n "$CWD" ]; then
  GIT_BRANCH=$(git --no-optional-locks -C "$CWD" branch --show-current 2>/dev/null)
  if [ -n "$GIT_BRANCH" ]; then
    MOD_COUNT=$(git --no-optional-locks -C "$CWD" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    NEW_COUNT=$(git --no-optional-locks -C "$CWD" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    [ "$MOD_COUNT" -gt 0 ] && GIT_DIRTY="${GIT_DIRTY} ${B_YELLOW}~${MOD_COUNT}${RESET}"
    [ "$NEW_COUNT" -gt 0 ] && GIT_DIRTY="${GIT_DIRTY} ${B_GREEN}+${NEW_COUNT}${RESET}"

    # Last commit age
    COMMIT_EPOCH=$(git --no-optional-locks -C "$CWD" log -1 --format='%ct' 2>/dev/null)
    if [ -n "$COMMIT_EPOCH" ]; then
      NOW_EPOCH=$(date +%s)
      AGE_SECS=$(( NOW_EPOCH - COMMIT_EPOCH ))
      AGE_MINS=$(( AGE_SECS / 60 ))
      AGE_HRS=$(( AGE_SECS / 3600 ))
      AGE_DAYS=$(( AGE_SECS / 86400 ))
      if   [ "$AGE_MINS" -lt 1 ];  then GIT_AGE="\033[1;32mnow${RESET}"
      elif [ "$AGE_HRS"  -lt 1 ];  then GIT_AGE="\033[1;32m${AGE_MINS}m${RESET}"
      elif [ "$AGE_HRS"  -lt 24 ]; then GIT_AGE="\033[1;33m${AGE_HRS}h${RESET}"
      elif [ "$AGE_DAYS" -lt 7 ];  then GIT_AGE="\033[38;5;208m${AGE_DAYS}d${RESET}"
      else                               GIT_AGE="\033[1;31m${AGE_DAYS}d${RESET}"
      fi
    fi
  fi
fi

# ─── Visual context bar ──────────────────────────────────────────────────────
CTX_SECTION=""
if [ -n "$CTX_PCT" ]; then
  CTX_COL=$(colour_gradient "$CTX_INT")
  BAR=$(context_bar "$CTX_INT")
  CTX_SECTION="${BAR} ${CTX_COL}${CTX_INT}%${RESET}"
fi

# ─── Lines changed ───────────────────────────────────────────────────────────
LINES_SECTION=""
if [ -n "$LINES_ADD" ] && [ -n "$LINES_REM" ]; then
  if [ "$LINES_ADD" -gt 0 ] || [ "$LINES_REM" -gt 0 ]; then
    LINES_SECTION="${B_GREEN}+${LINES_ADD}${RESET} ${B_RED}-${LINES_REM}${RESET}"
  fi
fi

# ─── Weather (cached 10 min, open-meteo.com) ────────────────────────────────
WEATHER_SECTION=""
WEATHER_CACHE="$HOME/.claude/weather_cache.json"
WEATHER_TTL=600

_wmo_desc() {
  case $1 in
    0) echo "Clear" ;; 1) echo "Mostly Clear" ;; 2) echo "Partly Cloudy" ;;
    3) echo "Overcast" ;; 45|48) echo "Foggy" ;;
    51|53|55) echo "Drizzle" ;; 61|63|65) echo "Rain" ;;
    71|73|75|77) echo "Snow" ;; 80|81|82) echo "Showers" ;;
    85|86) echo "Snow Showers" ;; 95|96|99) echo "Thunderstorm" ;;
    *) echo "" ;;
  esac
}

_load_weather() {
  local data="" now age mod_time
  if [ -f "$WEATHER_CACHE" ]; then
    now=$(date +%s)
    mod_time=$(stat -c %Y "$WEATHER_CACHE" 2>/dev/null || stat -f %m "$WEATHER_CACHE" 2>/dev/null || echo 0)
    age=$(( now - mod_time ))
    [ "$age" -lt "$WEATHER_TTL" ] && data=$(cat "$WEATHER_CACHE" 2>/dev/null)
  fi
  if [ -z "$data" ]; then
    data=$(curl -sf --max-time 3 "https://api.open-meteo.com/v1/forecast?latitude=-27.47&longitude=153.03&current=temperature_2m,weather_code&timezone=auto" 2>/dev/null)
    [ -n "$data" ] && printf '%s' "$data" > "$WEATHER_CACHE" 2>/dev/null
  fi
  [ -n "$data" ] && printf '%s' "$data"
}

WEATHER_DATA=$(_load_weather 2>/dev/null)
if [ -n "$WEATHER_DATA" ]; then
  W_TEMP=$(printf '%s' "$WEATHER_DATA" | jq -r '.current.temperature_2m // empty' 2>/dev/null)
  W_CODE=$(printf '%s' "$WEATHER_DATA" | jq -r '.current.weather_code // empty' 2>/dev/null)
  if [ -n "$W_TEMP" ]; then
    W_DESC=$(_wmo_desc "$W_CODE")
    WEATHER_SECTION="${DIM}${W_TEMP}°C${RESET}"
    [ -n "$W_DESC" ] && WEATHER_SECTION="${WEATHER_SECTION} ${DIM}${W_DESC}${RESET}"
  fi
fi

# ─── MCP servers (cached 5 min) ──────────────────────────────────────────────
MCP_SECTION=""
MCP_CACHE="$HOME/.claude/mcp_status_cache.json"
MCP_TTL=300

_load_mcp() {
  local data="" now age mod_time
  if [ -f "$MCP_CACHE" ]; then
    now=$(date +%s)
    mod_time=$(stat -c %Y "$MCP_CACHE" 2>/dev/null || stat -f %m "$MCP_CACHE" 2>/dev/null || echo 0)
    age=$(( now - mod_time ))
    [ "$age" -lt "$MCP_TTL" ] && data=$(cat "$MCP_CACHE" 2>/dev/null)
  fi
  if [ -z "$data" ]; then
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
    [ -z "$token" ] && return 1
    data=$(curl -sf --max-time 3 \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: mcp-servers-2025-12-04" \
      -H "anthropic-version: 2023-06-01" \
      "https://api.anthropic.com/v1/mcp_servers?limit=1000" 2>/dev/null)
    [ -n "$data" ] && printf '%s' "$data" > "$MCP_CACHE" 2>/dev/null
  fi
  [ -n "$data" ] && printf '%s' "$data"
}

MCP_NAMES=""

# Cloud MCP servers (filter to relevant ones only)
MCP_DATA=$(_load_mcp 2>/dev/null)
if [ -n "$MCP_DATA" ]; then
  MCP_NAMES=$(printf '%s' "$MCP_DATA" | jq -r '.data[].display_name' 2>/dev/null | tr -d '\r' | while read -r name; do
    case "$name" in
      monday.com|Monday*) printf "Mon " ;;
      Gmail*|Google*Calendar*) ;;  # skip — not needed
      *)                  printf "%s " "$(echo "$name" | cut -c1-4)" ;;
    esac
  done | sed 's/ $//')
fi

# Local MCP: NITA (check if uvicorn is listening on port 8000)
NITA_STATUS=""
if netstat -ano 2>/dev/null | grep -q ':8000.*LISTENING' || \
   ss -tlnp 2>/dev/null | grep -q ':8000'; then
  NITA_STATUS="${B_GREEN}NITA${RESET}"
else
  NITA_STATUS="${B_RED}NITA${RESET}"
fi

# Combine
MCP_PARTS=""
[ -n "$MCP_NAMES" ] && MCP_PARTS="$MCP_NAMES"
if [ -n "$NITA_STATUS" ]; then
  [ -n "$MCP_PARTS" ] && MCP_PARTS="${MCP_PARTS} "
  MCP_PARTS="${MCP_PARTS}${NITA_STATUS}"
fi
[ -n "$MCP_PARTS" ] && MCP_SECTION="${B_GREEN}MCP:${RESET}${DIM}${MCP_PARTS}${RESET}"

# ─── Session duration ─────────────────────────────────────────────────────────
DURATION_SECTION=""
if [ -n "$DURATION_MS" ] && [ "$DURATION_MS" != "0" ]; then
  TOTAL_SECS=$(( DURATION_MS / 1000 ))
  TOTAL_MINS=$(( TOTAL_SECS / 60 ))
  if [ "$TOTAL_MINS" -ge 60 ]; then
    HRS=$(( TOTAL_MINS / 60 ))
    MINS=$(( TOTAL_MINS % 60 ))
    DURATION_SECTION="${DIM}${HRS}h${MINS}m${RESET}"
  else
    DURATION_SECTION="${DIM}${TOTAL_MINS}m${RESET}"
  fi
fi

# ─── Day and time ─────────────────────────────────────────────────────────────
TIME_SECTION="${DIM}$(date '+%A %H:%M')${RESET}"

# ─── Vim mode ─────────────────────────────────────────────────────────────────
VIM_SECTION=""
if [ -n "$VIM_MODE" ]; then
  case "$VIM_MODE" in
    NORMAL) VIM_SECTION="${B_GREEN}NOR${RESET}" ;;
    INSERT) VIM_SECTION="${B_YELLOW}INS${RESET}" ;;
    *)      VIM_SECTION="${GREY}${VIM_MODE}${RESET}" ;;
  esac
fi

# ─── Cache hit ratio ─────────────────────────────────────────────────────────
CACHE_SECTION=""
if [ -n "$CACHE_READ" ] && [ -n "$CACHE_CREATE" ]; then
  CACHE_TOTAL=$(( CACHE_READ + CACHE_CREATE ))
  if [ "$CACHE_TOTAL" -gt 0 ]; then
    CACHE_PCT=$(awk "BEGIN {printf \"%.0f\", ($CACHE_READ / $CACHE_TOTAL) * 100}")
    C=$(colour_gradient "$CACHE_PCT")
    CACHE_SECTION="${C}Cache:${CACHE_PCT}%${RESET}"
  fi
fi

# ─── Assembly (two lines) ────────────────────────────────────────────────────
LINE1=""

# Model name
[ -n "$MODEL" ] && LINE1="${B_ORANGE}${MODEL}${RESET}"

# Directory
if [ -n "$DIR_NAME" ]; then
  [ -n "$LINE1" ] && LINE1="${LINE1}  "
  LINE1="${LINE1}${B_CYAN}${DIR_NAME}${RESET}"
fi

# Git branch + dirty + commit age
if [ -n "$GIT_BRANCH" ]; then
  [ -n "$LINE1" ] && LINE1="${LINE1}${SEP}"
  LINE1="${LINE1}${B_GREEN}${GIT_BRANCH}${RESET}${GIT_DIRTY}"
  [ -n "$GIT_AGE" ] && LINE1="${LINE1} ${GIT_AGE}"
fi

# Visual context bar
if [ -n "$CTX_SECTION" ]; then
  [ -n "$LINE1" ] && LINE1="${LINE1}${SEP}"
  LINE1="${LINE1}${CTX_SECTION}"
fi

# Lines changed
if [ -n "$LINES_SECTION" ]; then
  [ -n "$LINE1" ] && LINE1="${LINE1}${SEP}"
  LINE1="${LINE1}${LINES_SECTION}"
fi

# MCP servers
if [ -n "$MCP_SECTION" ]; then
  [ -n "$LINE1" ] && LINE1="${LINE1}${SEP}"
  LINE1="${LINE1}${MCP_SECTION}"
fi

# Vim mode
if [ -n "$VIM_SECTION" ]; then
  [ -n "$LINE1" ] && LINE1="${LINE1}${SEP}"
  LINE1="${LINE1}${VIM_SECTION}"
fi

# Cache ratio
if [ -n "$CACHE_SECTION" ]; then
  [ -n "$LINE1" ] && LINE1="${LINE1}${SEP}"
  LINE1="${LINE1}${CACHE_SECTION}"
fi

# ─── Line 2: Duration, Weather, Day & Time ──────────────────────────────────
LINE2=""

# Duration
if [ -n "$DURATION_SECTION" ]; then
  LINE2="${DURATION_SECTION}"
fi

# Weather
if [ -n "$WEATHER_SECTION" ]; then
  [ -n "$LINE2" ] && LINE2="${LINE2}${SEP}"
  LINE2="${LINE2}${WEATHER_SECTION}"
fi

# Day and time
[ -n "$LINE2" ] && LINE2="${LINE2}${SEP}"
LINE2="${LINE2}${TIME_SECTION}"

printf '%b\n%b\n' "$LINE1" "$LINE2"
