# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

This is a custom statusline script for Claude Code. It runs as an external command that Claude Code invokes on each render, reads a JSON payload from stdin, and prints a single styled line to stdout.

## Current Status

### Working Features

| Feature | Source | Display | Colour |
|---------|--------|---------|--------|
| Model name | `model.display_name` | `Sonnet 4.6` | Bold orange |
| Directory (basename) | `workspace.current_dir` | `Custom-Statusline` | Bold cyan |
| Git branch + dirty | `git -C` live | `dev ~2 +1` | Green (branch), yellow (~modified), green (+new) |
| Context usage | `context_window.used_percentage` | `Ctx:45%` | Gradient: green/yellow/orange/red |
| Session duration | `cost.total_duration_ms` | `14m` or `1h23m` | Dim grey |
| Day and time | `date` command | `Friday 17:30` | Dim grey |
| Vim mode | `vim.mode` | `NOR` / `INS` | Green / Yellow (only when vim enabled) |
| Cache hit ratio | `cache_read` / `cache_creation` tokens | `Cache:87%` | Gradient (only when tokens present) |

### Layout

```
Opus 4.6  Custom-Statusline | main ~2 +1 | Ctx:45% | NOR | Cache:87% | 14m | Friday 17:30
```

### Not Implemented — 5h/7d Usage

The 5-hour and 7-day rate-limit utilization cannot be fetched from an external bash script:

- **OAuth API (`/api/oauth/usage`)**: Returns `{ five_hour: { utilization: 0-100 }, seven_day: { ... } }` but rejects OAuth tokens via raw HTTP (`curl`/`fetch`). Error: "OAuth authentication is currently not supported." Claude Code's internal Node.js SDK handles OAuth routing through a different code path.
- **Response headers**: The data also arrives via `anthropic-ratelimit-unified-{5h,7d}-utilization` headers on each `/v1/messages` API call, but these only exist in Claude Code's in-memory state — never persisted to disk.
- **Community projects** (claude-powerline, ccusage): Both parse local JSONL transcript files (`~/.claude/projects/<hash>/<session>.jsonl`) to approximate 5h usage from token counts + model pricing. Both are Node.js apps, not bash scripts.
- **PAI (danielmiessler)**: Also does not display usage data.

The feature is stubbed in the script. If Claude Code adds usage fields to the statusline JSON payload in the future, the sections will activate.

### Not Working — Terminal Tab Title

Setting the terminal tab title from the statusline script is blocked because Claude Code captures all output (stdout + stderr) from the statusline subprocess. Approaches tried:

1. **OSC escape to stdout** (`printf '\033]0;Title\007'`): Captured by Claude Code, never reaches terminal.
2. **OSC escape to stderr** (`>&2`): Also captured.
3. **Write to `/dev/tty`**: Fails on Windows Git Bash — "No such device or address".
4. **PowerShell** (`[Console]::Title`): Runs in its own subprocess, doesn't affect parent terminal.
5. **Python `SetConsoleTitleW`** (Windows kernel API): Sets the console title but Windows Terminal doesn't reflect it in tab titles.
6. **`cmd.exe /c title`**: Same issue — subprocess can't reach parent terminal.

**Current approach**: A `SessionStart` hook in `settings.json` that emits the OSC sequence via stderr. Requires session restart to fire. Still being tested.

## How the Statusline Works

Claude Code pipes a JSON object to the script's stdin containing fields like:

- `.model.display_name` — active model name
- `.workspace.current_dir` — absolute path of the working directory
- `.cost.total_duration_ms` — session duration in milliseconds
- `.context_window.used_percentage` — context fill level (0–100)
- `.context_window.current_usage.cache_read_input_tokens` — cache read tokens
- `.context_window.current_usage.cache_creation_input_tokens` — cache creation tokens
- `.vim.mode` — vim mode (`NORMAL`, `INSERT`) when vim mode is enabled
- `.version` — Claude Code version

The script must output **a single line** (no trailing newline issues). ANSI escape codes are supported for colour.

## Installation

**Dependencies**: `jq` (install via `scoop install jq` on Windows)

```bash
chmod +x ~/.claude/statusline.sh
```

Register in `~/.claude/settings.json`:
```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  }
}
```

## Development & Testing

```bash
# Full test with all features
echo '{"model":{"display_name":"Sonnet 4.6"},"workspace":{"current_dir":"C:/Users/rob/project"},"cost":{"total_duration_ms":840000},"context_window":{"used_percentage":45,"current_usage":{"cache_read_input_tokens":8000,"cache_creation_input_tokens":2000}},"vim":{"mode":"NORMAL"},"version":"1.0.80"}' | bash statusline.sh

# Graceful degradation (minimal JSON)
echo '{"model":{"display_name":"Sonnet 4.6"},"workspace":{"current_dir":"/tmp"}}' | bash statusline.sh

# Syntax check
bash -n statusline.sh

# Inspect raw ANSI codes
echo '{...}' | bash statusline.sh | cat -v
```

## Design Conventions

- All JSON parsing goes through `jq` with a `// empty` fallback to handle missing fields gracefully.
- Context percentage drives a colour gradient: green < 50%, yellow < 75%, orange < 90%, red ≥ 90%.
- Sections are separated by `|` labels in grey (`\033[90m`), keeping the line scannable at a glance.
- Guard every optional section (`[ -n "$VAR" ] && ...`) so the line degrades cleanly when data is absent.
- Git info is derived live via `git -C "$CWD"` with `--no-optional-locks` — keep these calls fast; avoid porcelain commands.
- Directory basename handles both `/` and `\` separators (`${CWD##*[/\\]}`) for Windows compatibility.
