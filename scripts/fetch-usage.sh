#!/bin/sh
# tak-cc-statusline / fetch-usage.sh
# Fetches Claude rate-limit usage and writes them to the cache.
#
# Cache layout (atomic write):
#   Line 1: five_hour.utilization (integer %)
#   Line 2: seven_day.utilization (integer %)
#   Line 3: five_hour.resets_at (raw ISO string)
#   Line 4: seven_day.resets_at (raw ISO string)

# Honor Claude Code's CLAUDE_CONFIG_DIR override, fallback to ~/.claude
CACHE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
USAGE_CACHE="${CACHE_DIR}/.statusline_usage_cache"
TOKEN_CACHE="${CACHE_DIR}/.statusline_token_cache"
LAST_ATTEMPT="${CACHE_DIR}/.statusline_fetch_attempt"
LOCK_DIR="${CACHE_DIR}/.statusline_fetch.lock"
TOKEN_TTL=900       # 15 minutes
STALE_LOCK=30       # seconds before a held lock is considered crashed
CREDS_FILE="${CACHE_DIR}/.credentials.json"

mkdir -p "$CACHE_DIR"

portable_mtime() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# --- atomic lock: prevent concurrent fetches ---
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	# Lock exists: check if it's stale (previous process crashed)
	lock_mtime=$(portable_mtime "$LOCK_DIR")
	if [ -n "$lock_mtime" ]; then
		lock_age=$(( $(date -u +%s) - lock_mtime ))
		[ "$lock_age" -lt 0 ] && lock_age=0
		if [ "$lock_age" -gt "$STALE_LOCK" ]; then
			rmdir "$LOCK_DIR" 2>/dev/null
			mkdir "$LOCK_DIR" 2>/dev/null || exit 0
		else
			exit 0
		fi
	else
		exit 0
	fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null; rm -f "${CACHE_DIR}/.statusline_body.tmp."* 2>/dev/null' EXIT INT TERM

# Mark attempt timestamp regardless of success/failure (throttles retries)
touch "$LAST_ATTEMPT" 2>/dev/null

# --- get_token: try cache, then Keychain (macOS), then credentials file (Linux/WSL) ---
get_token() {
	# 1. Try cache (must be non-empty)
	if [ -s "$TOKEN_CACHE" ]; then
		cache_mtime=$(portable_mtime "$TOKEN_CACHE")
		if [ -n "$cache_mtime" ]; then
			cache_age=$(( $(date -u +%s) - cache_mtime ))
			[ "$cache_age" -lt 0 ] && cache_age=0
			if [ "$cache_age" -lt "$TOKEN_TTL" ]; then
				cat "$TOKEN_CACHE" 2>/dev/null
				return
			fi
		fi
	fi

	token=""

	# 2. macOS: try Keychain
	if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
		creds_json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
		if [ -n "$creds_json" ]; then
			token=$(printf '%s' "$creds_json" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
		fi
	fi

	# 3. Fallback: credentials file (Linux/WSL default)
	if [ -z "$token" ] && [ -f "$CREDS_FILE" ]; then
		token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS_FILE" 2>/dev/null)
	fi

	if [ -n "$token" ]; then
		# Atomic write with restrictive perms; only mv if write succeeded
		tmp="${TOKEN_CACHE}.tmp.$$"
		if (umask 077; printf '%s' "$token" > "$tmp") 2>/dev/null; then
			chmod 600 "$tmp" 2>/dev/null
			mv -f "$tmp" "$TOKEN_CACHE"
		else
			rm -f "$tmp" 2>/dev/null
		fi
		printf '%s' "$token"
	fi
}

token=$(get_token)
[ -z "$token" ] && exit 0

# Capture body to a tmp file and HTTP status code to a variable.
# Cleaner than parsing them out of a combined output blob.
body_file="${CACHE_DIR}/.statusline_body.tmp.$$"
http_code=$(curl -s -m 3 \
	-o "$body_file" \
	-w '%{http_code}' \
	-H "accept: application/json" \
	-H "anthropic-beta: oauth-2025-04-20" \
	-H "authorization: Bearer $token" \
	-H "user-agent: claude-code/2.1.11" \
	"https://api.anthropic.com/oauth/usage" 2>/dev/null)

case "$http_code" in
	401|403)
		# Token rejected: invalidate cache so next run pulls a fresh one
		rm -f "$TOKEN_CACHE" "$body_file" 2>/dev/null
		exit 0
		;;
	2*)
		: # success, continue
		;;
	*)
		rm -f "$body_file" 2>/dev/null
		exit 0
		;;
esac

if [ ! -s "$body_file" ]; then
	rm -f "$body_file" 2>/dev/null
	exit 0
fi

# Parse all 4 fields; type-check utilization to reject non-numbers
parsed=$(jq -r '
	(.five_hour.utilization | if type == "number" then tostring else "" end),
	(.seven_day.utilization | if type == "number" then tostring else "" end),
	(.five_hour.resets_at // ""),
	(.seven_day.resets_at // "")
' "$body_file" 2>/dev/null)

rm -f "$body_file" 2>/dev/null

five_h_raw=$(printf '%s\n' "$parsed" | sed -n '1p')
seven_d_raw=$(printf '%s\n' "$parsed" | sed -n '2p')
five_h_reset=$(printf '%s\n' "$parsed" | sed -n '3p')
seven_d_reset=$(printf '%s\n' "$parsed" | sed -n '4p')

# Both utilizations must be valid numbers; otherwise skip cache write
if [ -n "$five_h_raw" ] && [ -n "$seven_d_raw" ]; then
	five_h=$(printf "%.0f" "$five_h_raw" 2>/dev/null)
	seven_d=$(printf "%.0f" "$seven_d_raw" 2>/dev/null)
	# Atomic write: only mv if printf succeeded fully (avoids corrupt cache on disk-full / SIGPIPE)
	tmp="${USAGE_CACHE}.tmp.$$"
	if printf '%s\n%s\n%s\n%s\n' "$five_h" "$seven_d" "$five_h_reset" "$seven_d_reset" > "$tmp" 2>/dev/null; then
		mv -f "$tmp" "$USAGE_CACHE"
	else
		rm -f "$tmp" 2>/dev/null
	fi
fi
