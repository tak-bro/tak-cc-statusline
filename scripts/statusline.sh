#!/bin/sh
# tak-cc-statusline / statusline.sh
# https://github.com/tak-bro/tak-cc-statusline

input=$(cat)
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
CACHE_BASE="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
USAGE_CACHE="${CACHE_BASE}/.statusline_usage_cache"
LAST_ATTEMPT="${CACHE_BASE}/.statusline_fetch_attempt"
USAGE_TTL=60      # refresh cache after 60s
RETRY_TTL=30      # don't retry failed fetch within 30s

# --- portable helpers (BSD/GNU compatible) ---

portable_mtime() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

portable_iso_to_epoch() {
	clean=$(echo "$1" | sed 's/\.[0-9]*//' | sed 's/[+-][0-9][0-9]:[0-9][0-9]$//' | sed 's/Z$//')
	date -u -d "$clean" "+%s" 2>/dev/null || \
		TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null
}

# --- single jq call: extract model, dir, used% with type check ---
# used% returns "" for non-numbers (missing, null, string) so we can detect properly
parsed=$(printf '%s' "$input" | jq -r '
	(.model.display_name // ""),
	(.workspace.current_dir // .cwd // ""),
	(.context_window.used_percentage | if type == "number" then tostring else "" end)
' 2>/dev/null)

model=$(printf '%s\n' "$parsed" | sed -n '1p' | sed -E 's/[[:space:]]*\([^)]*\)//g')
dir=$(printf '%s\n' "$parsed" | sed -n '2p')
used=$(printf '%s\n' "$parsed" | sed -n '3p')
dir_name=$(basename "$dir" 2>/dev/null)

# --- git branch (only if dir is provided; handles regular repos and worktrees) ---
branch=""
if [ -n "$dir" ]; then
	branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null \
	      || git -C "$dir" rev-parse --short HEAD 2>/dev/null)
fi

# --- usage stats from cache (single read block, then check freshness) ---
five_h=""
seven_d=""
five_h_reset=""
seven_d_reset=""
need_refresh=0
now_epoch=$(date -u +%s)

if [ -f "$USAGE_CACHE" ]; then
	# Single read block instead of 4 separate sed calls
	{
		IFS= read -r five_h
		IFS= read -r seven_d
		IFS= read -r five_h_reset
		IFS= read -r seven_d_reset
	} < "$USAGE_CACHE" 2>/dev/null
	cache_mtime=$(portable_mtime "$USAGE_CACHE")
	if [ -n "$cache_mtime" ]; then
		cache_age=$(( now_epoch - cache_mtime ))
		# Defensive: handle clock skew (negative age = future mtime)
		[ "$cache_age" -lt 0 ] && cache_age=0
		[ "$cache_age" -gt "$USAGE_TTL" ] && need_refresh=1
	fi
else
	need_refresh=1
fi

# Throttle: skip refresh if we attempted very recently (success or failure)
if [ "$need_refresh" = "1" ] && [ -f "$LAST_ATTEMPT" ]; then
	attempt_mtime=$(portable_mtime "$LAST_ATTEMPT")
	if [ -n "$attempt_mtime" ]; then
		attempt_age=$(( now_epoch - attempt_mtime ))
		[ "$attempt_age" -lt 0 ] && attempt_age=0
		[ "$attempt_age" -lt "$RETRY_TTL" ] && need_refresh=0
	fi
fi

if [ "$need_refresh" = "1" ] && [ -f "$SCRIPT_DIR/fetch-usage.sh" ]; then
	# </dev/null isolates stdin so backgrounded process doesn't share ours
	sh "$SCRIPT_DIR/fetch-usage.sh" </dev/null >/dev/null 2>&1 &
fi

# --- compute_delta: human-readable time until reset ---
compute_delta() {
	reset_epoch=$(portable_iso_to_epoch "$1")
	[ -z "$reset_epoch" ] && return
	diff=$((reset_epoch - now_epoch))
	if [ "$diff" -le 0 ]; then echo "now"; return; fi
	days=$((diff / 86400))
	hours=$(((diff % 86400) / 3600))
	minutes=$(((diff % 3600) / 60))
	if [ "$days" -gt 0 ]; then
		echo "${days}d ${hours}h"
	elif [ "$hours" -gt 0 ]; then
		echo "${hours}h ${minutes}m"
	else
		echo "${minutes}m"
	fi
}

# --- pick_color: ANSI color escape based on usage percentage ---
pick_color() {
	pct=$1
	if [ "$pct" -ge 90 ]; then
		printf '\033[38;2;225;85;100m'    # red       (>= 90%)
	elif [ "$pct" -ge 75 ]; then
		printf '\033[38;2;225;130;160m'   # rose pink (>= 75%)
	elif [ "$pct" -ge 50 ]; then
		printf '\033[38;2;230;195;110m'   # yellow    (>= 50%)
	else
		printf '\033[38;2;130;215;145m'   # green     (default)
	fi
}

# --- build_bar: progress bar; takes pre-computed color to avoid duplicate pick_color ---
build_bar() {
	pct=$1
	width=$2
	color=$3
	[ "$pct" -lt 0 ] && pct=0
	[ "$pct" -gt 100 ] && pct=100
	filled=$(((pct * width + 50) / 100))
	# Show at least 1 filled cell when pct > 0 so users see "yes, it's working"
	[ "$pct" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
	[ "$filled" -gt "$width" ] && filled=$width
	empty=$((width - filled))
	printf '%s' "$color"
	i=0
	while [ "$i" -lt "$filled" ]; do
		printf '█'
		i=$((i + 1))
	done
	printf '\033[0m\033[38;2;80;85;95m'
	i=0
	while [ "$i" -lt "$empty" ]; do
		printf '░'
		i=$((i + 1))
	done
	printf '\033[0m'
}

# --- context window ---
ctx_str=""
ctx_bar=""
ctx_color=""
# `used` is "" for non-numbers (jq type check above), so this check is reliable
if [ -n "$used" ]; then
	used_int=$(printf "%.0f" "$used" 2>/dev/null)
	if [ -n "$used_int" ]; then
		ctx_str="${used_int}%"
		ctx_color=$(pick_color "$used_int")
		ctx_bar=$(build_bar "$used_int" 10 "$ctx_color")
	fi
fi

# --- assemble single-line output ---
SEP="\033[90m | \033[0m"
DOT="\033[90m • \033[0m"

# model
printf "\033[38;5;208m\033[1m%s\033[22m\033[0m" "$model"

# folder • branch
printf "%b" "$SEP"
printf "\033[1m\033[38;2;76;208;222m%s\033[22m\033[0m" "$dir_name"
if [ -n "$branch" ]; then
	printf "%b" "$DOT"
	printf "\033[1m\033[38;2;192;103;222m%s\033[22m\033[0m" "$branch"
fi

# ctx with colored bar
if [ -n "$ctx_str" ]; then
	printf "%b" "$SEP"
	printf "%s " "$ctx_bar"
	printf "%s%s\033[0m" "$ctx_color" "$ctx_str"
fi

# 5h / 7d usage
if [ -n "$five_h" ]; then
	printf "%b" "$SEP"
	printf "\033[38;2;156;162;175m5h %s%%\033[0m" "$five_h"
	if [ -n "$five_h_reset" ]; then
		delta=$(compute_delta "$five_h_reset")
		[ -n "$delta" ] && printf " \033[2m\033[38;2;156;162;175m(%s)\033[0m" "$delta"
	fi
fi
if [ -n "$seven_d" ]; then
	if [ -n "$five_h" ]; then
		printf "%b" "$DOT"
	else
		printf "%b" "$SEP"
	fi
	printf "\033[38;2;156;162;175m7d %s%%\033[0m" "$seven_d"
	if [ -n "$seven_d_reset" ]; then
		delta=$(compute_delta "$seven_d_reset")
		[ -n "$delta" ] && printf " \033[2m\033[38;2;156;162;175m(%s)\033[0m" "$delta"
	fi
fi
