# Claude Code Statusline

A customizable status line for Claude Code showing real-time session information.

## Screenshot

```
My Session | ~/cc/statusline | [Opus 4.5] Context: 43% (87k/112k) | $0.15 | 5h: 34% → 3h5m | 7d: 5% → 5d6h | main*
```

## Features

- **Session name** - Custom session title (if set via `/title`)
- **Current directory** - Full path with `~` substitution for home directory
- **Model name** - Currently active Claude model
- **Mode indicator** - Shows when in plan/edit mode
- **Context window usage** - Percentage and token counts (used/remaining)
- **Session cost** - Theoretical cost (useful for usage-based plans)
- **5-hour rate limit** - Usage percentage with time until reset
- **7-day rate limit** - Usage percentage with time until reset
- **Git branch** - Current branch name
- **Git dirty indicator** - Red `*` when uncommitted changes exist

## Color Coding

Usage percentages are color-coded:
- **Green** - 0-59% usage
- **Yellow** - 60-79% usage
- **Red** - 80-100% usage

## Requirements

- `jq` - JSON parsing
- `curl` - API requests
- `git` - Branch/status detection (optional)
- `tac` - Transcript parsing (part of coreutils)

## Installation

1. Download the script to your Claude scripts directory:
   ```bash
   mkdir -p ~/.claude/scripts
   curl -fsSL https://raw.githubusercontent.com/stellarthemes/statusline/main/statusline.sh -o ~/.claude/scripts/statusline.sh
   chmod 755 ~/.claude/scripts/statusline.sh
   ```

2. Configure Claude Code to use it by adding to `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/scripts/statusline.sh"
     }
   }
   ```

3. Restart Claude Code.

## Platform Support

- **Linux** - Full support
- **macOS** - Full support (handles BSD `date`/`stat` differences)
- **Windows** - Not supported (use WSL)

## How It Works

The script receives JSON input from Claude Code via stdin containing session information. It:

1. Extracts model, directory, mode, and cost from the input JSON
2. Fetches rate limit data from Anthropic API (cached for 5 minutes)
3. Parses the session transcript to get accurate token usage
4. Detects git branch and uncommitted changes
5. Outputs a formatted status line with ANSI colors

### Credentials

On Linux, OAuth credentials are read from `~/.claude/.credentials.json`.
On macOS, credentials are read from the system Keychain.

### Caching

API usage data is cached in `/tmp/claude-usage-cache` for 5 minutes to avoid rate limiting.

## Configuration

Edit the script to customize:

- `CACHE_MAX_AGE` - How long to cache API data (default: 300 seconds)
- `CONTEXT_OVERHEAD` - Fudge factor for context tokens (default: 12000). The API's usage object doesn't include all context overhead (system prompt structure, tool formatting, special tokens). Adjust this if you add/remove MCP servers or custom agents to better match `/context` output.
- Color codes in the "ANSI Color Codes" section
- Output format in the "Final Output" section

## Notes

- **Context tokens** show `...` until the first API response is received
- **Cost** is theoretical if you're on a flat-rate plan
- **Rate limits** require valid OAuth credentials to display

## License

MIT
