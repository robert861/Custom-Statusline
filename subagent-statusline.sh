#!/usr/bin/env bash
# ~/.claude/subagent-statusline.sh — Custom rows for the subagent panel.
#
# Claude Code pipes a single JSON object on stdin containing the base hook
# fields plus `.columns` (usable row width) and a `.tasks` array. Each task has:
#   id, name, type, status, description, label, startTime, tokenCount,
#   tokenSamples, cwd
#
# For each row we want to override we print ONE line of JSON to stdout:
#   {"id":"<task id>","content":"<row body>"}
# Omit a task's id to keep its default row; emit empty content to hide it.
# Docs: https://code.claude.com/docs/en/statusline#subagent-status-lines
#
# Replaces the default `name · description · token count` row with:
#   <glyph> name   <elapsed>   <tokens> (<avg tok/s>)   description
# so ultracode / workflow fan-outs are legible without opening the agent panel.

JSON=$(cat)

# Capture a raw payload sample for format tuning: run `SUBAGENT_SL_DEBUG=1 claude`
[ -n "$SUBAGENT_SL_DEBUG" ] && printf '%s\n' "$JSON" >> "$HOME/.claude/subagent-sl-debug.json"

command -v jq >/dev/null 2>&1 || exit 0

COLS=$(printf '%s' "$JSON" | jq -r '.columns // 80' 2>/dev/null)
[ -z "$COLS" ] && COLS=80
NOW=$(date +%s)

# ─── Colours ─────────────────────────────────────────────────────────────────
RESET=$'\033[0m'; DIM=$'\033[2m'; GREY=$'\033[90m'
GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[1;36m'
RED=$'\033[1;31m'; ORANGE=$'\033[1;38;5;208m'

# ─── Helpers ─────────────────────────────────────────────────────────────────
fmt_tokens() {  # 12345 -> 12.3k, 2500000 -> 2.5M
  awk -v t="$1" 'BEGIN{
    if (t>=1000000) printf "%.1fM", t/1000000;
    else if (t>=1000) printf "%.1fk", t/1000;
    else printf "%d", t;
  }'
}

# startTime may be epoch-ms, epoch-s, or an ISO string — normalise to epoch-s.
start_epoch() {
  local s=$1
  case "$s" in
    ''|null) return ;;
    *[!0-9]*) date -d "$s" +%s 2>/dev/null ;;
    *) if [ "${#s}" -ge 13 ]; then echo $(( s / 1000 )); else echo "$s"; fi ;;
  esac
}

fmt_dur() {  # seconds -> 45s / 2m05s / 1h03m
  local sec=$1
  [ "$sec" -lt 0 ] 2>/dev/null && sec=0
  if   [ "$sec" -lt 60 ];   then printf '%ds' "$sec"
  elif [ "$sec" -lt 3600 ]; then printf '%dm%02ds' $(( sec/60 )) $(( sec%60 ))
  else printf '%dh%02dm' $(( sec/3600 )) $(( (sec%3600)/60 )); fi
}

# status string (fuzzy-matched) -> coloured glyph
status_glyph() {
  case "$1" in
    *run*|*progress*|*active*|*work*) printf '%s' "${GREEN}▸${RESET}" ;;
    *complet*|*done*|*success*|*finish*) printf '%s' "${GREEN}✓${RESET}" ;;
    *pend*|*queue*|*wait*) printf '%s' "${GREY}○${RESET}" ;;
    *fail*|*error*) printf '%s' "${RED}✗${RESET}" ;;
    *cancel*|*stop*|*abort*) printf '%s' "${YELLOW}⊘${RESET}" ;;
    *) printf '%s' "${GREY}•${RESET}" ;;
  esac
}

# ─── Emit one JSON line per task ─────────────────────────────────────────────
# Fields are joined with the unit separator (0x1F): tab is an IFS *whitespace*
# char, so `read` would collapse empty fields (e.g. a missing label) and shift
# every column. 0x1F is non-whitespace, so empty fields are preserved.
printf '%s' "$JSON" | jq -r '
  .tasks[]? | [
    (.id // ""),
    (.name // ""),
    (.label // ""),
    (.status // ""),
    (.tokenCount // 0),
    (.startTime // ""),
    (.description // "" | gsub("[\t\n]"; " "))
  ] | map(tostring) | join("")' | while IFS=$'\037' read -r id name label status tokens start desc; do
  [ -z "$id" ] && continue

  glyph=$(status_glyph "$status")

  # Name (fall back to label, which is what local agents actually populate),
  # capped so the prefix never blows out the row.
  name_src="${name:-$label}"
  [ -z "$name_src" ] && name_src="agent"
  # Local agents repeat the label verbatim as the description — don't print it twice.
  [ "$desc" = "$name_src" ] && desc=""
  name_disp="$name_src"
  [ "${#name_disp}" -gt 28 ] && name_disp="${name_disp:0:27}…"

  # Elapsed + average token rate since start
  elapsed=""; rate=""
  st=$(start_epoch "$start")
  if [ -n "$st" ]; then
    dur=$(( NOW - st ))
    elapsed=$(fmt_dur "$dur")
    if [ "$dur" -gt 0 ] && [ "$tokens" -gt 0 ] 2>/dev/null; then
      rate=$(awk -v t="$tokens" -v d="$dur" 'BEGIN{r=t/d; if(r>=1000)printf "%.1fk",r/1000; else printf "%.0f",r}')
    fi
  fi

  tok_disp=""
  if [ "$tokens" -gt 0 ] 2>/dev/null; then
    tok_disp="$(fmt_tokens "$tokens")"
    [ -n "$rate" ] && tok_disp="${tok_disp} ${rate}/s"
  fi

  # Budget remaining width for the description (glyph + space = 2 cols)
  plain="$name_disp"
  [ -n "$elapsed" ]  && plain="${plain}  ${elapsed}"
  [ -n "$tok_disp" ] && plain="${plain}  ${tok_disp}"
  avail=$(( COLS - 2 - ${#plain} - 3 ))
  desc_disp=""
  if [ -n "$desc" ] && [ "$avail" -gt 4 ]; then
    if [ "${#desc}" -gt "$avail" ]; then desc_disp="${desc:0:avail}…"; else desc_disp="$desc"; fi
  fi

  # Assemble the coloured row
  content="${glyph} ${CYAN}${name_disp}${RESET}"
  [ -n "$elapsed" ]   && content="${content}  ${DIM}${elapsed}${RESET}"
  [ -n "$tok_disp" ]  && content="${content}  ${YELLOW}${tok_disp}${RESET}"
  [ -n "$desc_disp" ] && content="${content}  ${GREY}${desc_disp}${RESET}"

  # jq safely JSON-escapes the ANSI control bytes into the content string
  jq -nc --arg id "$id" --arg content "$content" '{id:$id,content:$content}'
done
