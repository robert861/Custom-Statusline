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
| Vim mode | `vim.mode` | `NOR` / `INS` (other modes shown raw) | Green / Yellow (only when vim enabled) |
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

Claude Code pipes a JSON object to the script's stdin. Official reference: <https://code.claude.com/docs/en/statusline>.

**Fields the script currently reads:**

- `.model.display_name` — active model name
- `.workspace.current_dir` — absolute path of the working directory
- `.cost.total_duration_ms` — session duration in milliseconds
- `.cost.total_lines_added`, `.cost.total_lines_removed` — lines changed this session
- `.context_window.used_percentage` — context fill level (0–100)
- `.context_window.current_usage.cache_read_input_tokens` — cache read tokens
- `.context_window.current_usage.cache_creation_input_tokens` — cache creation tokens
- `.effort.level` — reasoning effort (`low`/`medium`/`high`/`xhigh`/`max`); absent if model doesn't support it. **Ultracode is not a distinct level — it reports as `xhigh`.**
- `.rate_limits.five_hour.{used_percentage,resets_at}`, `.rate_limits.seven_day.{used_percentage,resets_at}` — 0–100 + reset epoch; absent until first API call (Pro/Max only)
- `.vim.mode` — vim mode (`NORMAL`, `INSERT`, `VISUAL`, `VISUAL LINE`) when vim mode is enabled
- `.version` — Claude Code version

**Other available fields (not yet used) — see the docs for the full schema:**

- `.model.id` — model identifier (e.g. `claude-opus-4-8`)
- `.context_window.context_window_size` — max window in tokens (`200000`, or `1000000` for extended-context models)
- `.context_window.remaining_percentage`; top-level `.exceeds_200k_tokens` (bool)
- `.context_window.total_input_tokens`, `.total_output_tokens` — **as of v2.1.132 these are current context, not cumulative session totals**
- `.cost.total_cost_usd`, `.cost.total_api_duration_ms`
- `.workspace.repo.{host,owner,name}` — repo identity from the `origin` remote (avoids parsing it via `git`); also `.workspace.{project_dir,added_dirs,git_worktree}`
- `.pr.{number,url,review_state}` — open PR for the current branch (`review_state`: `approved`/`pending`/`changes_requested`/`draft`)
- `.agent.name` (`--agent`), `.session_name` (`--name`/`/rename`), `.session_id`, `.transcript_path`
- `.thinking.enabled`, `.output_style.name`, `.worktree.*` (`--worktree` sessions only)

The script must output **a single line** per `echo` (multiple `echo`s render as multiple rows). ANSI escape codes are supported for colour; OSC 8 sequences make text clickable.

### `statusLine` config options (settings.json)

- `padding` — extra horizontal spacing (chars); we use `0`.
- `hideVimModeIndicator: true` — **enabled.** Suppresses Claude Code's built-in `-- INSERT --` text so the mode isn't shown twice (the script renders `vim.mode` itself).
- `refreshInterval` — re-runs the command every N seconds on top of event-driven updates. Worth setting if the live clock / weather feel stale during idle (event triggers go quiet when the main session is waiting on subagents). Not currently set.
- Terminal size: `tput cols` can't see the real width (Claude Code captures output), but **`COLUMNS`/`LINES` env vars are exported** (v2.1.153+) if we ever want width-aware layout.

## Subagent Status Line (`subagent-statusline.sh`)

`subagentStatusLine` is a **separate** setting that customises each row in the subagent panel shown below the prompt (the rows you'd otherwise only watch by opening the agent panel during `/code-review ultra`, ultracode, or any workflow fan-out). It replaces the default `name · description · token count` row with our own formatting, so a fleet of subagents stays legible without drilling into the menu.

**How it differs from `statusLine`:** the command runs once per refresh tick and receives a **single JSON object** on stdin — the [base hook fields](https://code.claude.com/docs/en/hooks#common-input-fields) plus:

- `.columns` — usable row width (use it to size/truncate output)
- `.tasks[]` — one entry per visible subagent, each with `id`, `name`, `type`, `status`, `description`, `label`, `startTime`, `tokenCount`, `tokenSamples`, `cwd`

**Output contract:** print **one JSON line per row to override**, `{"id":"<task id>","content":"<row body>"}`. `content` is rendered as-is (ANSI colours + OSC 8 links OK). Omit a task's `id` to keep its default row; emit empty `content` to hide that row.

**What our script renders** per subagent:

```
<glyph> name   <elapsed>   <tokens> (<avg tok/s>)   description…
  ▸ green=running  ✓ green=done  ○ grey=pending  ✗ red=failed  ⊘ yellow=cancelled
```

- `elapsed` is `now − startTime`; `startTime` is normalised whether it arrives as epoch-ms, epoch-s, or an ISO string.
- token rate is the **average** since start (`tokenCount / elapsed`) — `tokenSamples` is not yet consumed.
- `description` is truncated to fit `.columns`; the name is capped at 28 chars.

**Implementation notes:**

- Fields are joined for `read` with the **unit separator (`0x1F`)**, not tab — tab is an IFS *whitespace* char, so `read` would collapse an empty field (e.g. a missing `label`) and shift every column. `IFS=$'\037'` preserves empty fields.
- `content` is emitted via `jq -nc --arg` so the ANSI control bytes are safely JSON-escaped.
- The exact formats of `startTime` and `tokenSamples` aren't pinned down in the docs, so parsing is defensive. To capture a real payload for tuning, launch with `SUBAGENT_SL_DEBUG=1 claude` — each invocation appends raw stdin to `~/.claude/subagent-sl-debug.json`.
- Same gating as `statusLine`: requires workspace trust, and is disabled if `disableAllHooks` is `true`.

Register alongside `statusLine` in `~/.claude/settings.json`:

```json
{
  "subagentStatusLine": {
    "type": "command",
    "command": "~/.claude/subagent-statusline.sh"
  }
}
```

## Installation

**Dependencies**: `jq` (install via `scoop install jq` on Windows)

```bash
chmod +x ~/.claude/statusline.sh ~/.claude/subagent-statusline.sh
```

Register in `~/.claude/settings.json`:
```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0,
    "hideVimModeIndicator": true
  },
  "subagentStatusLine": {
    "type": "command",
    "command": "~/.claude/subagent-statusline.sh"
  }
}
```

## Deployment

After editing either script in this repo, **always** copy it to the live location so changes take effect immediately:

```bash
cp statusline.sh ~/.claude/statusline.sh
cp subagent-statusline.sh ~/.claude/subagent-statusline.sh
```

The statusline renders on every Claude Code tick, so the update is picked up on the next render — no restart needed. (Toggling settings like `hideVimModeIndicator` does require the next interaction to reload settings.)

## Development & Testing

```bash
# Full test with all features
echo '{"model":{"display_name":"Sonnet 4.6"},"workspace":{"current_dir":"C:/Users/rob/project"},"cost":{"total_duration_ms":840000},"context_window":{"used_percentage":45,"current_usage":{"cache_read_input_tokens":8000,"cache_creation_input_tokens":2000}},"vim":{"mode":"NORMAL"},"version":"1.0.80"}' | bash statusline.sh

# Graceful degradation (minimal JSON)
echo '{"model":{"display_name":"Sonnet 4.6"},"workspace":{"current_dir":"/tmp"}}' | bash statusline.sh

# Syntax check
bash -n statusline.sh
bash -n subagent-statusline.sh

# Inspect raw ANSI codes
echo '{...}' | bash statusline.sh | cat -v

# Subagent rows: feed a tasks array, then render the content fields
echo '{"columns":100,"tasks":[{"id":"a1","name":"review:bugs","status":"running","tokenCount":48213,"startTime":1718000000000,"description":"verify findings"}]}' | bash subagent-statusline.sh | jq -r '.content'
```

## Design Conventions

- All JSON parsing goes through `jq` with a `// empty` fallback to handle missing fields gracefully.
- Context percentage drives a colour gradient: green < 50%, yellow < 75%, orange < 90%, red ≥ 90%.
- Sections are separated by `|` labels in grey (`\033[90m`), keeping the line scannable at a glance.
- Guard every optional section (`[ -n "$VAR" ] && ...`) so the line degrades cleanly when data is absent.
- Git info is derived live via `git -C "$CWD"` with `--no-optional-locks` — keep these calls fast; avoid porcelain commands.
- Directory basename handles both `/` and `\` separators (`${CWD##*[/\\]}`) for Windows compatibility.
