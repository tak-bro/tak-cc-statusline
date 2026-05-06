#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require('fs');
const path = require('path');
const os = require('os');
const readline = require('readline');
const { execSync } = require('child_process');

// Honor CLAUDE_CONFIG_DIR (matches Claude Code's own behavior)
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const SETTINGS_PATH = path.join(CLAUDE_DIR, 'settings.json');
const STATUSLINE_REL = path.join(CLAUDE_DIR, 'statusline.sh');
const STATUSLINE_CMD = `sh ${STATUSLINE_REL.replace(os.homedir(), '~')}`;
const PKG_SCRIPTS_DIR = path.join(__dirname, 'scripts');
const FILES = ['statusline.sh', 'fetch-usage.sh'];
const IS_TTY = process.stdin.isTTY && process.stdout.isTTY;
const FORCE_YES = process.argv.includes('--yes') || process.argv.includes('-y');

function ask(question) {
	return new Promise((resolve) => {
		const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
		rl.question(question, (ans) => { rl.close(); resolve(ans); });
	});
}

async function confirm(question, defaultYes = false) {
	if (FORCE_YES) {
		console.log(`${question} (--yes)`);
		return true;
	}
	// Non-TTY: assume default and log the choice for transparency
	if (!IS_TTY) {
		const choice = defaultYes ? 'yes' : 'no';
		console.log(`${question} (non-interactive: ${choice})`);
		return defaultYes;
	}
	const suffix = defaultYes ? '[Y/n]' : '[y/N]';
	const ans = (await ask(`${question} ${suffix} `)).trim().toLowerCase();
	if (!ans) return defaultYes;
	return ans === 'y' || ans === 'yes';
}

function checkDeps() {
	const missing = [];
	for (const cmd of ['jq', 'curl']) {
		try { execSync(`command -v ${cmd}`, { stdio: 'ignore', shell: '/bin/sh' }); }
		catch { missing.push(cmd); }
	}
	return missing;
}

// Atomic write: tmp + rename (filesystem-level atomicity on POSIX)
function atomicWrite(filepath, content, mode = 0o644) {
	const tmp = `${filepath}.tmp.${process.pid}`;
	try {
		fs.writeFileSync(tmp, content, { mode });
		fs.renameSync(tmp, filepath);
	} catch (e) {
		try { fs.unlinkSync(tmp); } catch (_) { /* ignore cleanup failure */ }
		throw e;
	}
}

async function main() {
	console.log('tak-cc-statusline installer');
	console.log(`Target: ${CLAUDE_DIR}\n`);

	// 0. Sanity check: do package files exist?
	if (!fs.existsSync(PKG_SCRIPTS_DIR)) {
		console.error(`✗  Package scripts directory missing: ${PKG_SCRIPTS_DIR}`);
		console.error('   The npm package may be corrupted. Try: npm cache clean --force');
		process.exit(1);
	}
	for (const f of FILES) {
		if (!fs.existsSync(path.join(PKG_SCRIPTS_DIR, f))) {
			console.error(`✗  Missing package file: scripts/${f}`);
			console.error('   The npm package may be corrupted. Try: npm cache clean --force');
			process.exit(1);
		}
	}

	// 1. Dependency check
	const missing = checkDeps();
	if (missing.length) {
		console.log(`⚠  Missing required tools: ${missing.join(', ')}`);
		console.log('   Install them first (e.g. brew install jq, apt install jq), then re-run.\n');
		if (!(await confirm('Continue anyway?'))) {
			process.exit(1);
		}
	}

	// 2. Ensure config dir exists
	fs.mkdirSync(CLAUDE_DIR, { recursive: true });

	// 3. Copy scripts (with overwrite prompt if file exists & differs)
	const installed = [];
	for (const f of FILES) {
		const src = path.join(PKG_SCRIPTS_DIR, f);
		const dst = path.join(CLAUDE_DIR, f);
		if (fs.existsSync(dst)) {
			const srcContent = fs.readFileSync(src, 'utf8');
			const dstContent = fs.readFileSync(dst, 'utf8');
			if (srcContent === dstContent) {
				console.log(`✓  ${f} already up to date`);
				installed.push(f);
				continue;
			}
			if (!(await confirm(`${dst} exists. Overwrite?`))) {
				console.log(`–  skipped ${f}`);
				continue;
			}
		}
		try {
			// Atomic copy via tmp + rename
			const content = fs.readFileSync(src);
			atomicWrite(dst, content, 0o755);
			console.log(`✓  installed ${dst}`);
			installed.push(f);
		} catch (e) {
			console.error(`✗  Failed to install ${f}: ${e.message}`);
			process.exit(1);
		}
	}

	if (installed.length === 0) {
		console.log('\n–  No scripts installed. Aborting settings update.');
		process.exit(0);
	}

	// 4. Update settings.json (atomic write to avoid corruption)
	let settings = {};
	if (fs.existsSync(SETTINGS_PATH)) {
		try {
			settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
		} catch (e) {
			console.log(`\n✗  Could not parse ${SETTINGS_PATH}: ${e.message}`);
			console.log('   Fix the JSON or add manually:');
			console.log(`   "statusLine": { "type": "command", "command": "${STATUSLINE_CMD}" }`);
			process.exit(1);
		}
	}

	const existing = settings.statusLine;
	// Preserve user-set fields like `padding` when overwriting, only changing
	// `type` and `command` to point at our scripts.
	const newConfig = existing && typeof existing === 'object'
		? { ...existing, type: 'command', command: STATUSLINE_CMD }
		: { type: 'command', command: STATUSLINE_CMD };

	const writeSettings = () => {
		try {
			atomicWrite(SETTINGS_PATH, JSON.stringify(settings, null, 2) + '\n');
		} catch (e) {
			console.error(`✗  Failed to write settings.json: ${e.message}`);
			console.error('   Add manually:');
			console.error(`   "statusLine": { "type": "command", "command": "${STATUSLINE_CMD}" }`);
			process.exit(1);
		}
	};

	if (existing && existing.command === STATUSLINE_CMD) {
		console.log('✓  statusLine already configured');
	} else if (existing) {
		console.log('\n   Existing statusLine.command:');
		console.log(`     ${existing.command || '(empty)'}`);
		if (await confirm('   Overwrite with tak-cc-statusline?')) {
			settings.statusLine = newConfig;
			writeSettings();
			console.log('✓  updated settings.json');
		} else {
			console.log('–  kept existing statusLine. To switch later, set:');
			console.log(`   "statusLine": { "type": "command", "command": "${STATUSLINE_CMD}" }`);
		}
	} else {
		settings.statusLine = newConfig;
		writeSettings();
		console.log('✓  added statusLine to settings.json');
	}

	console.log('\nDone. Restart Claude Code to see the new statusline.');
	console.log('First render shows blank usage stats — they appear on the second render.');
}

main().catch((err) => {
	console.error('\n✗  Installation failed:', err.message);
	process.exit(1);
});
