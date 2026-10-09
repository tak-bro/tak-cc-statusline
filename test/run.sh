#!/bin/sh
# Fixture tests for statusline.sh / fetch-usage.sh. No network, no real Keychain:
# `security` and `curl` are stubbed on PATH and HOME points at a scratch dir.
# Usage: sh test/run.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/home/.claude"
cp "$ROOT/scripts/statusline.sh" "$ROOT/scripts/fetch-usage.sh" "$T/home/.claude/"

cat > "$T/bin/security" <<'STUB'
#!/bin/sh
printf '{"claudeAiOauth":{"accessToken":"tok"}}'
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
	[ "$1" = -o ] && printf '%s' "$FAKE_BODY" > "$2"
	shift
done
printf 200
STUB
chmod +x "$T/bin/security" "$T/bin/curl"
# Linux has no Keychain: fetch-usage.sh falls back to this file
printf '{"claudeAiOauth":{"accessToken":"tok"}}' > "$T/home/.claude/.credentials.json"

export HOME="$T/home" PATH="$T/bin:$PATH"
unset CLAUDE_CONFIG_DIR
CACHE="$HOME/.claude/.statusline_usage_cache"
STDIN='{"model":{"display_name":"Opus 5.5"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":5}}'

ESC=$(printf '\033')
strip() { sed "s/${ESC}\[[0-9;]*m//g"; }   # BSD sed has no \x1b

pass=0
failed=0
check() { # name, haystack, grep -E pattern, [expect: present|absent]
	if printf '%s' "$2" | grep -Eq -- "$3"; then found=present; else found=absent; fi
	if [ "$found" = "${4:-present}" ]; then
		pass=$((pass + 1))
	else
		failed=$((failed + 1))
		printf 'FAIL %s: /%s/ %s in:\n%s\n' "$1" "$3" "${4:-present}" "$2"
	fi
}

iso_in() { # ISO-8601 UTC timestamp $1 seconds from now
	e=$(( $(date -u +%s) + $1 ))
	date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
}

# Writes a fresh cache (so statusline.sh never spawns a refresh) and renders.
render() { # five_h seven_d five_h_reset seven_d_reset scoped [label]
	if [ $# -ge 6 ]; then
		printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" "$5" "$6" > "$CACHE"
	else
		printf '%s\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" "$5" > "$CACHE"
	fi
	printf '%s' "$STDIN" | sh "$HOME/.claude/statusline.sh" | strip
}

# --- account badge ---
out=$(render 3 43 "$(iso_in 3600)" "$(iso_in 86400)" "Fable:11")
check "legacy 5-line cache has no badge" "$out" "@" absent
check "legacy 5-line cache still shows usage" "$out" "5h 3%"

out=$(render 3 43 "$(iso_in 3600)" "$(iso_in 86400)" "Fable:11" "louis")
check "badge opens the usage group" "$out" "@louis 5h 3%"

out=$(render "" "" "" "" "" "louis")
check "badge hidden without numbers" "$out" "@louis" absent

# fetch-usage writes the label of the logged-in account
printf '%s' '{"oauthAccount":{"accountUuid":"u1","emailAddress":"ma;ny\tbad.chars-ok@example.com"}}' > "$HOME/.claude.json"
export FAKE_BODY='{"five_hour":{"utilization":7,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":8,"resets_at":"2030-01-01T00:00:00Z"}}'
rm -f "$CACHE"
sh "$HOME/.claude/fetch-usage.sh"
check "fetch writes sanitized, cut label as line 6" "$(sed -n 6p "$CACHE")" "^manybad.char$"
check "fetch keeps lines 1-2" "$(sed -n 1,2p "$CACHE" | tr '\n' ' ')" "^7 8 $"

echo '{}' > "$HOME/.claude.json"
rm -f "$CACHE"
sh "$HOME/.claude/fetch-usage.sh"
check "no account → empty label line" "[$(sed -n 6p "$CACHE")]" "^\\[\\]$"

# --- pace warning ---
D=86400
out=$(render "" 50 "" "$(iso_in $((5 * D)))" "")
check "7d ahead of pace warns" "$out" "7d 50% \([^)]*\) ![0-9]"
out=$(render "" 20 "" "$(iso_in $((5 * D)))" "")
check "7d on pace no warning" "$out" "!" absent
out=$(render "" 50 "" "$(iso_in $((13 * D / 2)))" "")
check "7d under 10% elapsed no warning" "$out" "!" absent
out=$(render "" 0 "" "$(iso_in $((5 * D)))" "")
check "7d used 0 no warning" "$out" "!" absent
out=$(render "" 100 "" "$(iso_in $((5 * D)))" "")
check "7d used 100 no warning" "$out" "!" absent
out=$(render "" 50 "" "$(iso_in -60)" "")
check "7d reset passed no warning" "$out" "!" absent
out=$(render 90 "" "$(iso_in 3600)" "" "")
check "5h ahead of pace warns" "$out" "5h 90% \([^)]*\) ![0-9]"

# --- width: a narrow pane splits rows instead of overflowing ---
# mid-bucket resets: a second ticking between renders must not change the countdown width
render 80 50 "$(iso_in 5400)" "$(iso_in $((5 * D + D / 2)))" "Fable:11;Sonnet:4" "louis" > /dev/null
out=$(printf '%s' "$STDIN" | COLUMNS=60 sh "$HOME/.claude/statusline.sh" | strip)
check "narrow pane splits into two rows" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "^2$"
out=$(printf '%s' "$STDIN" | COLUMNS=200 sh "$HOME/.claude/statusline.sh" | strip)
# wc -m counts characters only under a UTF-8 locale; pick whichever is installed
utf8=$(locale -a 2>/dev/null | grep -iE '^en_US\.utf-?8$' | head -1)
[ -n "$utf8" ] || utf8=$(locale -a 2>/dev/null | grep -iE '^C\.utf-?8$' | head -1)
w=$(printf '%s' "$out" | LC_ALL=${utf8:-en_US.UTF-8} wc -m | tr -d ' ')
check "wide pane stays on one row" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "^1$"
# the split decision is only right if the counted width equals the printed width
COUNT=$(printf '%s' "$STDIN" | COLUMNS=$((w + 2)) sh "$HOME/.claude/statusline.sh" | wc -l | tr -d ' ')
check "line exactly fitting COLUMNS stays one row" "$COUNT" "^0$"
COUNT=$(printf '%s' "$STDIN" | COLUMNS=$((w + 1)) sh "$HOME/.claude/statusline.sh" | wc -l | tr -d ' ')
check "one column short splits" "$COUNT" "^1$"

printf '%s passed, %s failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
