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
BAR_WIDTH=10      # cells in the context bar
SEP_W=3           # visible width of the " | " / " • " separators
WIDTH_MARGIN=2    # columns held back for statusLine padding and rounding

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
	(.effort.level // ""),
	(.workspace.current_dir // .cwd // ""),
	(.context_window.used_percentage | if type == "number" then tostring else "" end)
' 2>/dev/null)

model=$(printf '%s\n' "$parsed" | sed -n '1p' | sed -E 's/[[:space:]]*\([^)]*\)//g')
effort=$(printf '%s\n' "$parsed" | sed -n '2p')
dir=$(printf '%s\n' "$parsed" | sed -n '3p')
used=$(printf '%s\n' "$parsed" | sed -n '4p')
dir_name=$(basename "$dir" 2>/dev/null)

# Append reasoning effort (dot style) to model when Claude Code reports it
[ -n "$effort" ] && model="${model} · ${effort}"

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
scoped=""
need_refresh=0
now_epoch=$(date -u +%s)

if [ -f "$USAGE_CACHE" ]; then
	# Single read block instead of separate sed calls.
	# Line 5 is absent in caches written by older versions; `scoped` stays empty.
	{
		IFS= read -r five_h
		IFS= read -r seven_d
		IFS= read -r five_h_reset
		IFS= read -r seven_d_reset
		IFS= read -r scoped
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
		ctx_bar=$(build_bar "$used_int" "$BAR_WIDTH" "$ctx_color")
	fi
fi

# --- validate the scoped records once, so width and output agree ---
# Output is "Name:pct;" for every record that survives; malformed ones are dropped.
scoped_clean=""
if [ -n "$scoped" ]; then
	set -f   # scoped is unquoted below; keep the shell from globbing it
	old_ifs=$IFS
	IFS=';'
	for record in $scoped; do
		# name may itself contain ":", so split on the LAST colon
		name=${record%:*}
		pct=${record##*:}
		[ -z "$name" ] && continue
		case "$pct" in ''|*[!0-9]*) continue ;; esac
		scoped_clean="${scoped_clean}${name}:${pct};"
	done
	IFS=$old_ifs
	set +f
fi

# --- reset deltas: computed once, used for both width and output ---
five_h_delta=""
seven_d_delta=""
[ -n "$five_h" ] && [ -n "$five_h_reset" ] && five_h_delta=$(compute_delta "$five_h_reset")
[ -n "$seven_d" ] && [ -n "$seven_d_reset" ] && seven_d_delta=$(compute_delta "$seven_d_reset")

# --- visible widths, counted rather than measured ---
# ANSI escapes never reach these numbers, and the multibyte glyphs (the bar cells,
# the separator dots) are counted as the one column they occupy. `${#var}` is only
# applied to the plain strings; a non-ASCII branch or folder name may overcount
# under a byte-counting /bin/sh, which wraps a little early but never truncates.
w_model=${#model}

w_dir=${#dir_name}
[ -n "$branch" ] && w_dir=$((w_dir + SEP_W + ${#branch}))

w_ctx=0
[ -n "$ctx_str" ] && w_ctx=$((BAR_WIDTH + 1 + ${#ctx_str}))

w_usage=0
if [ -n "$five_h" ]; then
	w_usage=$((w_usage + 3 + ${#five_h} + 1))          # "5h NN%"
	[ -n "$five_h_delta" ] && w_usage=$((w_usage + 3 + ${#five_h_delta}))   # " (1h 19m)"
fi
if [ -n "$seven_d" ]; then
	[ "$w_usage" -gt 0 ] && w_usage=$((w_usage + SEP_W))
	w_usage=$((w_usage + 3 + ${#seven_d} + 1))
	[ -n "$seven_d_delta" ] && w_usage=$((w_usage + 3 + ${#seven_d_delta}))
fi
if [ -n "$scoped_clean" ]; then
	set -f
	old_ifs=$IFS
	IFS=';'
	for record in $scoped_clean; do
		[ -z "$record" ] && continue
		[ "$w_usage" -gt 0 ] && w_usage=$((w_usage + SEP_W))
		w_usage=$((w_usage + ${#record}))   # "Name:pct" is as wide as "Name pct%"
	done
	IFS=$old_ifs
	set +f
fi

# --- decide where the line breaks ---
# Claude Code truncates each status line rather than soft-wrapping it, so anything
# past the terminal width is lost. Groups are packed greedily: a group that would
# overflow starts a new line instead. With no COLUMNS (or a wide terminal) every
# group lands on one line and the output is byte-identical to the single-line form.
usable=0
case "${COLUMNS:-}" in
	''|*[!0-9]*) : ;;
	*) usable=$((COLUMNS - WIDTH_MARGIN)) ;;
esac

cur=0
nl=0
nl_dir=0
nl_ctx=0
nl_usage=0

# Places one group and reports, via `nl`, whether it had to start a new line.
place_group() {
	nl=0
	if [ "$cur" -eq 0 ]; then
		cur=$1
		return
	fi
	if [ "$usable" -gt 0 ] && [ $((cur + SEP_W + $1)) -gt "$usable" ]; then
		nl=1
		cur=$1
	else
		cur=$((cur + SEP_W + $1))
	fi
}

[ "$w_model" -gt 0 ] && place_group "$w_model"
[ "$w_dir"   -gt 0 ] && { place_group "$w_dir";   nl_dir=$nl; }
[ "$w_ctx"   -gt 0 ] && { place_group "$w_ctx";   nl_ctx=$nl; }
[ "$w_usage" -gt 0 ] && { place_group "$w_usage"; nl_usage=$nl; }

# --- assemble output ---
SEP="\033[90m | \033[0m"
DOT="\033[90m • \033[0m"
emitted=0

# Emits the separator that belongs before a group: nothing when it opens the
# output, a newline when it opens a line, " | " otherwise.
open_group() {
	if [ "$emitted" = "1" ]; then
		if [ "$1" = "1" ]; then
			printf '\n'
		else
			printf "%b" "$SEP"
		fi
	fi
	emitted=1
}

# model
if [ "$w_model" -gt 0 ]; then
	open_group 0
	printf "\033[38;5;208m\033[1m%s\033[22m\033[0m" "$model"
fi

# folder • branch
if [ "$w_dir" -gt 0 ]; then
	open_group "$nl_dir"
	printf "\033[1m\033[38;2;76;208;222m%s\033[22m\033[0m" "$dir_name"
	if [ -n "$branch" ]; then
		printf "%b" "$DOT"
		printf "\033[1m\033[38;2;192;103;222m%s\033[22m\033[0m" "$branch"
	fi
fi

# ctx with colored bar
if [ "$w_ctx" -gt 0 ]; then
	open_group "$nl_ctx"
	printf "%s " "$ctx_bar"
	printf "%s%s\033[0m" "$ctx_color" "$ctx_str"
fi

# 5h / 7d / per-model usage
if [ "$w_usage" -gt 0 ]; then
	open_group "$nl_usage"
	usage_shown=0
	if [ -n "$five_h" ]; then
		printf "\033[38;2;156;162;175m5h %s%%\033[0m" "$five_h"
		[ -n "$five_h_delta" ] && printf " \033[2m\033[38;2;156;162;175m(%s)\033[0m" "$five_h_delta"
		usage_shown=1
	fi
	if [ -n "$seven_d" ]; then
		[ "$usage_shown" = "1" ] && printf "%b" "$DOT"
		printf "\033[38;2;156;162;175m7d %s%%\033[0m" "$seven_d"
		[ -n "$seven_d_delta" ] && printf " \033[2m\033[38;2;156;162;175m(%s)\033[0m" "$seven_d_delta"
		usage_shown=1
	fi
	# per-model weekly usage (e.g. "Fable 12%"); shares the 7d reset, so no delta
	if [ -n "$scoped_clean" ]; then
		set -f
		old_ifs=$IFS
		IFS=';'
		for record in $scoped_clean; do
			[ -z "$record" ] && continue
			[ "$usage_shown" = "1" ] && printf "%b" "$DOT"
			printf "\033[38;2;156;162;175m%s %s%%\033[0m" "${record%:*}" "${record##*:}"
			usage_shown=1
		done
		IFS=$old_ifs
		set +f
	fi
fi
