#!/usr/bin/env node
/* eslint-disable no-console */
// Renders the README screenshots: runs the real scripts/statusline.sh against fixture
// caches and turns its ANSI output into SVG, so the pictures can never drift from the
// code. Needs jq (like the statusline itself). Usage: node docs/make-screenshots.js
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const OUT = path.join(__dirname, 'img');

// --- scratch HOME with the real script, a fixture cache and fake repos ---
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'statusline-shots-'));
process.on('exit', () => fs.rmSync(tmp, { recursive: true, force: true }));
const claudeDir = path.join(tmp, 'home', '.claude');
fs.mkdirSync(claudeDir, { recursive: true });
fs.copyFileSync(path.join(ROOT, 'scripts', 'statusline.sh'), path.join(claudeDir, 'statusline.sh'));
const cache = path.join(claudeDir, '.statusline_usage_cache');

function fakeRepo(name, branch) {
	// just enough of a repo for `git symbolic-ref --short HEAD`; no git binary needed here
	const dir = path.join(tmp, 'work', name);
	fs.mkdirSync(path.join(dir, '.git', 'objects'), { recursive: true });
	fs.mkdirSync(path.join(dir, '.git', 'refs'), { recursive: true });
	fs.writeFileSync(path.join(dir, '.git', 'HEAD'), `ref: refs/heads/${branch}\n`);
	return dir;
}

const iso = (seconds) => new Date(Date.now() + seconds * 1000).toISOString().replace(/\.\d+Z$/, 'Z');
const H = 3600;
const D = 86400;

// One statusline render. Reset offsets sit mid-bucket so the countdown is stable.
function render({ model, effort, session, branch, ctx, fiveH, sevenD, scoped = '', account, columns }) {
	const dir = fakeRepo(session, branch);
	const lines = [
		fiveH ? fiveH.pct : '',
		sevenD.pct,
		fiveH ? iso(fiveH.reset) : '',
		iso(sevenD.reset),
		scoped,
		account,
	];
	fs.writeFileSync(cache, lines.join('\n') + '\n');
	const stdin = JSON.stringify({
		model: { display_name: model },
		effort: { level: effort },
		workspace: { current_dir: dir },
		session_name: session,
		context_window: { used_percentage: ctx },
	});
	const env = { ...process.env, HOME: path.join(tmp, 'home') };
	delete env.CLAUDE_CONFIG_DIR;
	if (columns) env.COLUMNS = String(columns);
	const run = spawnSync('sh', [path.join(claudeDir, 'statusline.sh')], { input: stdin, env, encoding: 'utf8' });
	if (run.status !== 0 || !run.stdout) throw new Error(`statusline.sh failed: ${run.stderr}`);
	return run.stdout;
}

// --- ANSI → cells ---
const DEFAULT_FG = [192, 197, 208];
const ANSI_GRAY = [128, 132, 142]; // \033[90m
const TRACK = [56, 59, 69]; // the empty part of the bar: rgb(80,85,95) at 55% over the window color

function xterm256(n) {
	if (n === 208) return [255, 135, 0];
	throw new Error(`unhandled 256-color ${n}`);
}

function parse(ansi) {
	const rows = [[]];
	let fg = DEFAULT_FG;
	let bold = false;
	let dim = false;
	const re = /\x1b\[([0-9;]*)m|([^\x1b])/g;
	let m;
	while ((m = re.exec(ansi))) {
		if (m[2] !== undefined) {
			if (m[2] === '\n') rows.push([]);
			else rows[rows.length - 1].push({ ch: m[2], fg, bold, dim });
			continue;
		}
		const p = m[1].split(';').map(Number);
		if (p[0] === 38 && p[1] === 2) fg = [p[2], p[3], p[4]];
		else if (p[0] === 38 && p[1] === 5) fg = xterm256(p[2]);
		else if (p[0] === 90) fg = ANSI_GRAY;
		else if (p[0] === 0 || m[1] === '') { fg = DEFAULT_FG; bold = false; dim = false; }
		else if (p[0] === 1) bold = true;
		else if (p[0] === 2) dim = true;
		else if (p[0] === 22) { bold = false; dim = false; }
		else throw new Error(`unhandled SGR ${m[1]}`);
	}
	return rows.filter((r) => r.length);
}

// --- SVG ---
const FONT = 15;
const CW = 9; // cell width: 0.6 em of a monospace font
const LH = 26; // row height
const PAD_X = 26;
const PAD_Y = 22;
const BAR_H = 18;
const FONT_STACK = "'JetBrains Mono','SF Mono',Menlo,Consolas,'DejaVu Sans Mono',monospace";
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const rgb = (c) => `rgb(${c[0]},${c[1]},${c[2]})`;

function drawRow(cells, y) {
	let out = '';
	let run = null;
	const flush = () => {
		if (!run) return;
		const w = run.bold ? ' font-weight="700"' : '';
		const o = run.dim ? ' opacity=".6"' : '';
		out += `<text x="${run.xs.join(' ')}" y="${y}" fill="${rgb(run.fg)}"${w}${o}>${esc(run.text)}</text>`;
		run = null;
	};
	cells.forEach((c, i) => {
		const x = PAD_X + i * CW;
		if (c.ch === '█' || c.ch === '░') {
			flush();
			const solid = c.ch === '█';
			out += `<rect x="${x}" y="${y - BAR_H + 4}" width="${CW + 0.5}" height="${BAR_H}" fill="${rgb(solid ? c.fg : TRACK)}"/>`;
			return;
		}
		if (c.ch === ' ') {
			flush();
			return;
		}
		const same = run && run.fg === c.fg && run.bold === c.bold && run.dim === c.dim;
		if (!same) {
			flush();
			run = { fg: c.fg, bold: c.bold, dim: c.dim, text: '', xs: [] };
		}
		run.text += c.ch;
		run.xs.push(x);
	});
	flush();
	return out;
}

function svg(title, ansi) {
	const rows = parse(ansi);
	const cols = Math.max(...rows.map((r) => r.length));
	const winW = Math.max(cols * CW + PAD_X * 2, 560);
	const barH = 38;
	const winH = barH + PAD_Y * 2 + (rows.length - 1) * LH + 14;
	const body = rows.map((r, i) => drawRow(r, barH + PAD_Y + 12 + i * LH)).join('');
	return `<svg xmlns="http://www.w3.org/2000/svg" width="${winW}" height="${winH}" viewBox="0 0 ${winW} ${winH}" role="img" aria-label="${esc(title)}">
<g>
<rect width="${winW}" height="${winH}" rx="12" fill="#1a1b26"/>
<path d="M0 12a12 12 0 0 1 12-12h${winW - 24}a12 12 0 0 1 12 12v${barH - 12}H0z" fill="#24253a"/>
<circle cx="22" cy="${barH / 2}" r="6" fill="#ff5f56"/><circle cx="42" cy="${barH / 2}" r="6" fill="#ffbd2e"/><circle cx="62" cy="${barH / 2}" r="6" fill="#27c93f"/>
<text x="${winW / 2}" y="${barH / 2 + 5}" text-anchor="middle" fill="#7a7f93" font-size="13" font-family="${FONT_STACK}">${esc(title)}</text>
<g font-family="${FONT_STACK}" font-size="${FONT}">${body}</g>
</g>
</svg>
`;
}

// --- scenes ---
const hero = {
	model: 'Opus 5.5',
	effort: 'high',
	session: 'prepare-deploy',
	branch: 'feature/louis-prepare-deploy',
	ctx: 7,
	fiveH: { pct: 21, reset: 3 * H + 12 * 60 + 30 },
	sevenD: { pct: 63, reset: 4 * D + 2 * H + 1800 },
	scoped: 'Fable:12',
	account: 'louis',
};

const scenes = [
	['statusline', 'claude — tak-cc-statusline', [render(hero)]],
	[
		'ultra',
		'claude — Ultra: no 5-hour window, so no 5h segment',
		[
			render({
				...hero,
				session: 'ship-it',
				branch: 'main',
				ctx: 9,
				fiveH: null,
				sevenD: { pct: 24, reset: 4 * D + 12 * H + 1800 },
				scoped: 'Fable:0',
			}),
		],
	],
	[
		'colors',
		'claude — context bar: green → yellow → rose → red',
		[12, 55, 80, 95].map((ctx) =>
			render({ ...hero, session: 'colors', branch: 'main', ctx, fiveH: { pct: 10, reset: 2 * H + 1800 }, sevenD: { pct: 20, reset: 5 * D + 1800 }, scoped: '' }),
		),
	],
	['narrow', 'claude — narrow pane: splits into two rows', [render({ ...hero, columns: 62 })]],
];

fs.mkdirSync(OUT, { recursive: true });
for (const [name, title, renders] of scenes) {
	const file = path.join(OUT, `${name}.svg`);
	fs.writeFileSync(file, svg(title, renders.map((r) => r.replace(/\n$/, '')).join('\n')));
	console.log(`wrote ${path.relative(ROOT, file)}`);
}
