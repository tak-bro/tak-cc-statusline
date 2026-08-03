# tak-cc-statusline

A minimal, colorful single-line statusline for [Claude Code](https://claude.com/claude-code).

```
Opus 4.6 · high | encl • feature/louis-prepare-deploy | █░░░░░░░░░ 7% | 5h 21% (3h 12m) • 7d 3% (6d 9h) • Fable 12%
```

## Install

```sh
npx -y tak-cc-statusline@latest
```

That's it. Restart Claude Code. First render shows blank usage stats — they appear on the second.

The installer prompts before overwriting any existing `statusLine` config or scripts. Existing fields like `padding` are preserved when updating.

> **Workspace trust required.** Claude Code only runs statusline commands in directories you've accepted the workspace trust dialog for. If you see `statusline skipped · restart to fix`, open Claude Code in that directory and accept the trust prompt.

## Requirements

`jq`, `curl`, Node 14+ (for the installer only). Works on macOS and Linux. Honors `$CLAUDE_CONFIG_DIR` if you've set it.

## What it shows

| Segment | Source |
|---|---|
| Model · effort | Claude Code, with `(1M context)` etc. stripped; reasoning effort (`.effort.level`) appended when reported |
| Folder · branch | cwd + `git symbolic-ref` |
| Context bar + % | Claude Code's `context_window.used_percentage` |
| 5h / 7d % | Anthropic OAuth usage endpoint (cached 60s) |
| Per-model weekly % | Same endpoint's model-scoped weekly limits (e.g. `Fable 12%`); shown only when your plan has them, and labeled with whatever name the API reports |

Bar color: green `< 50%`, yellow `≥ 50%`, rose `≥ 75%`, red `≥ 90%`.

## Customize

Both scripts live in `~/.claude/` after install — edit them in place.

- **Colors**: `pick_color()` in `statusline.sh`
- **Bar width**: the `10` in `build_bar "$used_int" 10`
- **Bar characters**: `█` and `░` in `build_bar()` — try `▓`/`▒`, `■`/`□`, `▰`/`▱`
- **Model / folder / branch colors**: search for `\033[38;2;` near the bottom

## Troubleshooting

**`statusline skipped · restart to fix`**

You haven't accepted the workspace trust dialog for the current directory. Restart Claude Code in that folder and accept the trust prompt — statusLine commands run shell scripts, so they require the same trust as hooks.

**Usage stats don't appear**

```sh
sh ~/.claude/fetch-usage.sh
cat ~/.claude/.statusline_usage_cache
```

If empty, your OAuth token couldn't be read. macOS: check Keychain for `Claude Code-credentials`. Linux: check `~/.claude/.credentials.json` exists.

**API returns 401**

The hardcoded `user-agent: claude-code/2.1.11` may need bumping. Edit `fetch-usage.sh`.

**Reset the caches**

```sh
rm ~/.claude/.statusline_usage_cache ~/.claude/.statusline_token_cache
```

## Uninstall

```sh
rm ~/.claude/statusline.sh ~/.claude/fetch-usage.sh
rm -f ~/.claude/.statusline_usage_cache ~/.claude/.statusline_token_cache
```

Then remove the `statusLine` block from `~/.claude/settings.json`.

## Credits

Forked from [xleddyl/claude-watch](https://github.com/xleddyl/claude-watch) — most of the heavy lifting (rate-limit fetching, color scheme, original layout) is theirs. This package adds:

- npm one-liner install with conflict-aware prompts
- macOS + Linux portability
- `$CLAUDE_CONFIG_DIR` support
- Background fetch with locking, atomic writes, and retry throttling

## License

MIT

