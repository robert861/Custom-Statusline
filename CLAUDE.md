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
| Effort level | `.effort.level` (JSON payload) | `Max` / `XHi` / `Hi` / `Med` / `Lo` | Red / Orange / Green / Yellow / Dim grey |
| Rate limits | `.rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` | `5h:23%/45% 7d:91%/30%` | Usage: gradient; elapsed: dim |

### Layout

```
Opus 4.7 Hi  Custom-Statusline | main ~2 +1 | Ctx:45% | NOR | Cache:87%
14m | 5h:23% 7d:91% | 16.8°C Clear | Friday 17:30
```

### Rate limits (5h / 7d)

As of Claude Code v1.2.80+, `rate_limits.five_hour` and `rate_limits.seven_day` ship in the statusline JSON payload (Pro/Max subscribers, present after the first API response in a session). Each window exposes `used_percentage` and `resets_at` (Unix epoch). Each window may be independently absent — the script uses `// empty` guards and renders whichever values are available.

The display shows `5h:USED%/ELAPSED%` where ELAPSED is computed from `resets_at` against fixed window sizes (18000s for 5h, 604800s for 7d). Compare the two numbers at a glance: USED > ELAPSED means you're burning quota faster than the window refills.

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
- `.effort.level` — reasoning effort (`low`/`medium`/`high`/`xhigh`/`max`); absent if model doesn't support it
- `.rate_limits.five_hour.used_percentage`, `.rate_limits.seven_day.used_percentage` — 0–100; absent until first API call (Pro/Max only)
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

## Deployment

After editing `statusline.sh` in this repo, **always** copy it to the live location so changes take effect immediately:

```bash
cp statusline.sh ~/.claude/statusline.sh
```

The statusline renders on every Claude Code tick, so the update is picked up on the next render — no restart needed.

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
