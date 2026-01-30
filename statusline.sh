#!/bin/bash
# ==============================================================================
# Claude Code Status Line
# ==============================================================================
# This script creates a rich status line for Claude Code showing:
# - Current model being used
# - Mode (if in plan/edit mode)
# - Context window usage percentage
# - API usage limits (5-hour and 7-day windows) with time until reset
# - Current git branch
#
# Usage: Configure this script in your Claude Code settings as a statusline hook
# Requirements: jq, curl, git (optional)
#
# The script expects JSON input from Claude Code via stdin
# ==============================================================================

input=$(cat)

# ==============================================================================
# Extract Model and Directory Information
# ==============================================================================
MODEL=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
CWD=$(echo "$input" | jq -r '.cwd // empty')
# Show full path, but replace $HOME with ~
DIR_NAME="${CWD/#$HOME/\~}"

# ==============================================================================
# Session Name (custom title if set)
# ==============================================================================
SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')
PROJECT_DIR=$(echo "$input" | jq -r '.workspace.project_dir // empty')
SESSION_NAME=""

if [ -n "$SESSION_ID" ] && [ -n "$PROJECT_DIR" ]; then
    # Convert project path to Claude's escaped format (/ becomes -)
    ESCAPED_PROJECT_DIR=$(echo "$PROJECT_DIR" | sed 's|^/|-|; s|/|-|g')
    SESSIONS_INDEX="$HOME/.claude/projects/${ESCAPED_PROJECT_DIR}/sessions-index.json"
    SESSION_JSONL="$HOME/.claude/projects/${ESCAPED_PROJECT_DIR}/${SESSION_ID}.jsonl"

    # Try sessions-index.json first
    if [ -f "$SESSIONS_INDEX" ]; then
        SESSION_NAME=$(jq -r --arg sid "$SESSION_ID" '.entries[] | select(.sessionId == $sid) | .customTitle // empty' "$SESSIONS_INDEX" 2>/dev/null)
    fi

    # Fallback: read from session transcript (for freshly renamed sessions)
    if [ -z "$SESSION_NAME" ] && [ -f "$SESSION_JSONL" ]; then
        SESSION_NAME=$(grep '"type":"custom-title"' "$SESSION_JSONL" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
    fi
fi

# ==============================================================================
# Session Cost (theoretical - flat rate plan)
# ==============================================================================
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
if [ "$COST" != "0" ] && [ -n "$COST" ]; then
    COST_DISPLAY=$(printf "$%.2f" "$COST")
else
    COST_DISPLAY="\$0.00"
fi

# ==============================================================================
# API Usage Limits Fetching (with caching)
# ==============================================================================
# Fetches usage data from Anthropic API and caches it to avoid rate limiting
# Cache expires after 5 minutes to keep data reasonably fresh
CACHE_FILE="/tmp/claude-usage-cache"
CACHE_MAX_AGE=300

fetch_usage_limits() {
    # Retrieves OAuth credentials and fetches usage data
    # Supports both Linux (file-based) and macOS (Keychain)
    local creds token

    # Try Linux credentials file first
    local creds_file="$HOME/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        creds=$(cat "$creds_file" 2>/dev/null)
    elif command -v security &>/dev/null; then
        # Fall back to macOS Keychain
        creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    fi

    if [ -z "$creds" ]; then
        echo ""
        return
    fi

    # Extract OAuth access token from credentials JSON
    token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty')
    if [ -z "$token" ]; then
        echo ""
        return
    fi

    # Query Anthropic API for usage statistics (5-hour and 7-day windows)
    curl -s --max-time 2 -H "Authorization: Bearer $token" \
         -H "anthropic-beta: oauth-2025-04-20" \
         https://api.anthropic.com/api/oauth/usage
}

get_usage_limits() {
    # Returns cached usage data if fresh, otherwise fetches new data
    # This prevents hammering the API on every statusline refresh
    if [ -f "$CACHE_FILE" ]; then
        local cache_mtime
        # Linux uses stat -c %Y, macOS uses stat -f %m
        if stat --version &>/dev/null 2>&1; then
            cache_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
        else
            cache_mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
        fi
        local cache_age=$(($(date +%s) - cache_mtime))
        if [ "$cache_age" -lt "$CACHE_MAX_AGE" ]; then
            cat "$CACHE_FILE"
            return
        fi
    fi

    # Cache is stale or missing - fetch fresh data
    local data
    data=$(fetch_usage_limits)
    if [ -n "$data" ]; then
        echo "$data" > "$CACHE_FILE"
        echo "$data"
    fi
}

# ==============================================================================
# Time Formatting Helper
# ==============================================================================
# Converts ISO 8601 timestamp to human-readable relative time
# Examples: "2h30m", "3d5h", "45m", "now"
format_time_until() {
    local reset_at="$1"
    if [ -z "$reset_at" ] || [ "$reset_at" = "null" ]; then
        echo ""
        return
    fi

    # Parse ISO timestamp (e.g., "2025-12-31T23:59:59.000Z") and convert to epoch
    # Supports both GNU date (Linux) and BSD date (macOS)
    local reset_epoch now_epoch diff

    # Try GNU date first (Linux), then fall back to BSD date (macOS)
    reset_epoch=$(date -d "$reset_at" "+%s" 2>/dev/null)
    if [ -z "$reset_epoch" ]; then
        # macOS fallback
        reset_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${reset_at%%.*}" "+%s" 2>/dev/null)
    fi

    if [ -z "$reset_epoch" ]; then
        echo ""
        return
    fi
    now_epoch=$(date +%s)
    diff=$((reset_epoch - now_epoch))

    if [ "$diff" -le 0 ]; then
        echo "now"
        return
    fi

    # Calculate days, hours, and minutes
    local days hours mins
    days=$((diff / 86400))
    hours=$(((diff % 86400) / 3600))
    mins=$(((diff % 3600) / 60))

    # Format output based on magnitude (show top 2 units)
    if [ "$days" -gt 0 ]; then
        echo "${days}d${hours}h"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h${mins}m"
    else
        echo "${mins}m"
    fi
}

# Fetch usage limits from API
USAGE_LIMITS=$(get_usage_limits)

# ==============================================================================
# Extract Mode Information
# ==============================================================================
# Mode shows if Claude is in a special state (e.g., "plan", "edit")
MODE=$(echo "$input" | jq -r '.mode // empty')
if [ -z "$MODE" ]; then
    MODE_DISPLAY=""
else
    MODE_DISPLAY=" | ${MODE} |"
fi

# ==============================================================================
# Context Window Usage Calculation
# ==============================================================================
# Calculate percentage of context window used
# Try multiple sources: current_usage, total tokens, or parse transcript
#
# FUDGE FACTOR: The API's usage object doesn't include all context overhead
# (system prompt structure, tool definitions formatting, special tokens, etc.)
# This approximates the gap between API-reported tokens and /context's accounting.
# Adjust if you add/remove MCP servers or custom agents.
CONTEXT_OVERHEAD=12000
CONTEXT_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
USAGE=$(echo "$input" | jq '.context_window.current_usage // null')
TRANSCRIPT_PATH=$(echo "$input" | jq -r '.transcript_path // empty')

# Try to get token count from current_usage first
if [ "$USAGE" != "null" ] && [ "$USAGE" != "{}" ]; then
    # Include output_tokens as they also consume context space
    CURRENT=$(echo "$USAGE" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens + .output_tokens')
else
    # Fall back to total_input_tokens + total_output_tokens
    TOTAL_IN=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
    TOTAL_OUT=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
    CURRENT=$((TOTAL_IN + TOTAL_OUT))
fi

# If still 0, try parsing the transcript file for the last usage entry
if [ "$CURRENT" -eq 0 ] 2>/dev/null && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Get the last message with usage data (most recent API response)
    LAST_USAGE=$(tac "$TRANSCRIPT_PATH" 2>/dev/null | grep -m1 '"usage"' | jq -r '.message.usage // empty' 2>/dev/null)
    if [ -n "$LAST_USAGE" ]; then
        INPUT_T=$(echo "$LAST_USAGE" | jq -r '.input_tokens // 0')
        CACHE_CREATE=$(echo "$LAST_USAGE" | jq -r '.cache_creation_input_tokens // 0')
        CACHE_READ=$(echo "$LAST_USAGE" | jq -r '.cache_read_input_tokens // 0')
        OUTPUT_T=$(echo "$LAST_USAGE" | jq -r '.output_tokens // 0')
        CURRENT=$((INPUT_T + CACHE_CREATE + CACHE_READ + OUTPUT_T))
    fi
fi

if [ "$CURRENT" -gt 0 ] 2>/dev/null; then
    # Add overhead to approximate /context's accounting
    CURRENT=$((CURRENT + CONTEXT_OVERHEAD))
    PERCENT=$((CURRENT * 100 / CONTEXT_SIZE))
    TOKENS_USED=$CURRENT
    TOKENS_LEFT=$((CONTEXT_SIZE - CURRENT))
else
    # No usage data yet - show "..." to indicate waiting for first API response
    PERCENT=0
    TOKENS_USED="..."
    TOKENS_LEFT="..."
fi

# Format tokens for display (k suffix)
format_tokens() {
    local tokens=$1
    # Handle non-numeric values like "..."
    if ! [[ "$tokens" =~ ^[0-9]+$ ]]; then
        echo "$tokens"
        return
    fi
    if [ "$tokens" -ge 1000 ]; then
        echo "$((tokens / 1000))k"
    else
        echo "$tokens"
    fi
}

TOKENS_USED_FMT=$(format_tokens "$TOKENS_USED")
TOKENS_LEFT_FMT=$(format_tokens "$TOKENS_LEFT")

# ==============================================================================
# Color Coding Helper
# ==============================================================================
# Returns ANSI color code based on usage percentage
# Green (0-59%), Yellow (60-79%), Red (80-100%)
get_color() {
    local pct=$1
    if [ "$pct" -ge 80 ]; then
        echo "\033[31m"  # Red
    elif [ "$pct" -ge 60 ]; then
        echo "\033[33m"  # Yellow
    else
        echo "\033[32m"  # Green
    fi
}

# ==============================================================================
# ANSI Color Codes
# ==============================================================================
RESET="\033[0m"
CYAN="\033[36m"
MAGENTA="\033[35m"
WHITE="\033[97m"
RED="\033[31m"
GREEN="\033[32m"

# Apply color to context percentage
CTX_COLOR=$(get_color "$PERCENT")

# ==============================================================================
# Parse API Usage Limits
# ==============================================================================
# Anthropic enforces two rate limit windows:
# - 5-hour rolling window
# - 7-day rolling window
# This section displays both usage percentages with time until reset
if [ -n "$USAGE_LIMITS" ]; then
    # Extract utilization percentages (strip decimal places)
    FIVE_HOUR=$(echo "$USAGE_LIMITS" | jq -r '.five_hour.utilization // empty' | cut -d. -f1)
    SEVEN_DAY=$(echo "$USAGE_LIMITS" | jq -r '.seven_day.utilization // empty' | cut -d. -f1)
    FIVE_RESET=$(echo "$USAGE_LIMITS" | jq -r '.five_hour.resets_at // empty')
    SEVEN_RESET=$(echo "$USAGE_LIMITS" | jq -r '.seven_day.resets_at // empty')

    if [ -n "$FIVE_HOUR" ] && [ -n "$SEVEN_DAY" ]; then
        # Apply color coding to each limit
        FIVE_COLOR=$(get_color "$FIVE_HOUR")
        SEVEN_COLOR=$(get_color "$SEVEN_DAY")

        # Convert reset timestamps to human-readable format
        FIVE_TIME=$(format_time_until "$FIVE_RESET")
        SEVEN_TIME=$(format_time_until "$SEVEN_RESET")

        # Build display strings with colored percentages and reset times
        FIVE_DISPLAY="5h: ${FIVE_COLOR}${FIVE_HOUR}%${RESET}"
        [ -n "$FIVE_TIME" ] && FIVE_DISPLAY="${FIVE_DISPLAY} → ${MAGENTA}${FIVE_TIME}${RESET}"

        SEVEN_DISPLAY="7d: ${SEVEN_COLOR}${SEVEN_DAY}%${RESET}"
        [ -n "$SEVEN_TIME" ] && SEVEN_DISPLAY="${SEVEN_DISPLAY} → ${MAGENTA}${SEVEN_TIME}${RESET}"

        LIMITS_DISPLAY=" | ${FIVE_DISPLAY} | ${SEVEN_DISPLAY}"
    else
        LIMITS_DISPLAY=""
    fi
else
    LIMITS_DISPLAY=""
fi

# ==============================================================================
# Git Branch and Status Detection
# ==============================================================================
# Shows current git branch and dirty indicator if in a git repository
# Uses -C to specify directory and --no-optional-locks to prevent lock files
GIT_DISPLAY=""
if git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git -C "$CWD" --no-optional-locks branch --show-current 2>/dev/null)
    if [ -n "$BRANCH" ]; then
        # Check for uncommitted changes
        if [ -n "$(git -C "$CWD" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
            DIRTY="${RED}*${RESET}"
        else
            DIRTY=""
        fi
        GIT_DISPLAY=" | ${CYAN}${BRANCH}${RESET}${DIRTY}"
    fi
fi

# ==============================================================================
# Final Output
# ==============================================================================
# Assemble all components into final statusline
# Format: [session] dir | [Model] | mode | Context: XX% (usedK/leftK) | cost | 5h: XX% → Xh | 7d: XX% → Xd | branch*
SESSION_DISPLAY=""
[ -n "$SESSION_NAME" ] && SESSION_DISPLAY="${MAGENTA}${SESSION_NAME}${RESET} | "

echo -e "${SESSION_DISPLAY}${CYAN}${DIR_NAME}${RESET} | [${MODEL}]${MODE_DISPLAY} ${WHITE}Context:${RESET} ${CTX_COLOR}${PERCENT}%${RESET} (${TOKENS_USED_FMT}/${TOKENS_LEFT_FMT}) | ${GREEN}${COST_DISPLAY}${RESET}${LIMITS_DISPLAY}${GIT_DISPLAY}"
