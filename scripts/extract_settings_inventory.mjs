#!/usr/bin/env node
// extract_settings_inventory.mjs — derive the runtime `settings.json` surface
// from upstream's own sources.
//
// Why this exists
// ---------------
// `settings.json` is written by the browser (public/script.js `saveSettings()`),
// not by the server, so its shape is defined in the *client* code. The module
// claims those settings are Nix-drivable, but nothing in the repo enumerates
// them: `settings.common` is a free-form blob, so a typo'd key is accepted
// silently and then ignored by the server.
//
// This script derives the real list — the same way `.opencode/skills/
// nix-coverage/scripts/audit.py` derives the `config.yaml` surface — so the
// inventory cannot go stale silently. It never hardcodes a key.
//
// Output: lib/settings-inventory.json
//
// Usage: node scripts/extract_settings_inventory.mjs [--check]
//   --check  exit 1 if the committed file differs from the freshly derived one

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'lib', 'settings-inventory.json');

// ── the evaluation sandbox ───────────────────────────────────────────────────
//
// The upstream default objects are JavaScript literals that reference module
// constants (`tokenizers.BEST_MATCH`, `avatar_styles.ROUND`, …). We want the
// *keys* and their *shapes*; where a value cannot be resolved statically we
// record it as `unknown` rather than guessing.
//
// UNKNOWN is a callable proxy: reading any property off it, or calling it,
// yields UNKNOWN again. That lets an unresolved constant like
// `tokenizers.BEST_MATCH` be evaluated without throwing.
//
// The lookup happens inside a `with (SENTINEL) { … }` block: `with` is the
// only construct that lets us resolve an *arbitrary* identifier to a value.
// (Using vm's own global proxy does not work — an unresolved identifier there
// resolves to the sandbox global, so a spread of an imported object silently
// copied every global into the result.)

const UNKNOWN = new Proxy(function () {}, {
    get(target, prop) {
        if (prop === Symbol.toPrimitive) return () => 'unknown';
        if (prop === 'then') return undefined; // not a thenable
        if (prop === Symbol.iterator) return undefined;
        return UNKNOWN;
    },
    apply() {
        return UNKNOWN;
    },
    ownKeys() {
        return [];
    },
});

const REAL_GLOBALS = {
    console: { log() {}, warn() {}, error() {} },
    Math,
    JSON,
    Date,
    Number,
    String,
    Boolean,
    Array,
    Object,
    structuredClone,
    undefined,
    NaN,
    Infinity,
};

function makeContext() {
    const ctx = vm.createContext({ ...REAL_GLOBALS });
    // `known` holds the constants harvested from upstream. The proxy makes any
    // *other* identifier resolve to UNKNOWN instead of throwing, so a literal
    // that references an unavailable constant still yields its other keys.
    const known = {};
    const sentinel = new Proxy(known, {
        has: () => true,
        get(target, prop) {
            if (prop in target) return target[prop];
            if (prop === 'globalThis') return ctx;
            if (prop in REAL_GLOBALS) return REAL_GLOBALS[prop];
            if (typeof prop === 'symbol') return undefined;
            return UNKNOWN;
        },
    });
    ctx.__sentinel = sentinel;
    ctx.__known = known;
    return ctx;
}

/** Evaluate `text` as an expression, with unresolved names → UNKNOWN. */
function evaluate(ctx, text) {
    const script = `(function () { with (globalThis.__sentinel) { return (${text}); } })()`;
    return vm.runInContext(script, ctx);
}
// ── source scanning ─────────────────────────────────────────────────────────

/**
 * Find the source text of a `{ … }` object literal starting at `start`
 * (the index of the opening brace). Brace matching is string- and
 * comment-aware, because these literals contain template strings and
 * `//` comments.
 */
function extractBraced(source, start) {
    let depth = 0;
    let i = start;
    let inString = null;
    let inLineComment = false;
    let inBlockComment = false;
    while (i < source.length) {
        const ch = source[i];
        const next = source[i + 1];
        if (inLineComment) {
            if (ch === '\n') inLineComment = false;
        } else if (inBlockComment) {
            if (ch === '*' && next === '/') {
                inBlockComment = false;
                i++;
            }
        } else if (inString) {
            if (ch === '\\') {
                i++;
            } else if (ch === inString) {
                inString = null;
            }
        } else if (ch === '/' && next === '/') {
            inLineComment = true;
            i++;
        } else if (ch === '/' && next === '*') {
            inBlockComment = true;
            i++;
        } else if (ch === '"' || ch === "'" || ch === '`') {
            inString = ch;
        } else if (ch === '{') {
            depth++;
        } else if (ch === '}') {
            depth--;
            if (depth === 0) return source.slice(start, i + 1);
        }
        i++;
    }
    throw new Error('unbalanced braces');
}

/** Locate `const NAME = {` and return the object literal's source. */
function literalFor(source, name) {
    const re = new RegExp(`(?:export\\s+)?(?:const|let|var)\\s+${name}\\s*=\\s*\\{`, 'm');
    const m = re.exec(source);
    if (!m) return null;
    const braceIndex = source.indexOf('{', m.index + m[0].length - 1);
    return extractBraced(source, braceIndex);
}

/** Locate `const NAME = <expr>;` and return the expression source. */
function expressionFor(source, name) {
    const re = new RegExp(`(?:export\\s+)?(?:const|let|var)\\s+${name}\\s*=\\s*`, 'm');
    const m = re.exec(source);
    if (!m) return null;
    let i = m.index + m[0].length;
    let depth = 0;
    let inString = null;
    while (i < source.length) {
        const ch = source[i];
        if (inString) {
            if (ch === '\\') i++;
            else if (ch === inString) inString = null;
        } else if (ch === '"' || ch === "'" || ch === '`') {
            inString = ch;
        } else if (ch === '{' || ch === '[' || ch === '(') depth++;
        else if (ch === '}' || ch === ']' || ch === ')') depth--;
        else if (ch === ';' && depth === 0) break;
        i++;
    }
    return source.slice(m.index + m[0].length, i).trim();
}

/**
 * Harvest every top-level `const NAME = { … }` / `= [ … ]` / `= <scalar>`
 * from a file, so a surface literal can resolve the constants it references.
 */
function harvestConstants(source) {
    const out = [];
    const re = /(?:^|\n)\s*(?:export\s+)?(?:const|let)\s+([A-Za-z_$][\w$]*)\s*=\s*/g;
    let m;
    while ((m = re.exec(source)) !== null) {
        const name = m[1];
        const start = m.index + m[0].length;
        const ch = source[start];
        let text = null;
        if (ch === '{') {
            text = extractBraced(source, start);
        } else if (ch === '[') {
            // array literal: match the closing bracket
            let depth = 0;
            let i = start;
            while (i < source.length) {
                if (source[i] === '[') depth++;
                else if (source[i] === ']') {
                    depth--;
                    if (depth === 0) break;
                }
                i++;
            }
            text = source.slice(start, i + 1);
        } else if (ch === "'" || ch === '"' || ch === '`') {
            let i = start;
            const quote = ch;
            while (i < source.length) {
                if (source[i] === '\\') i++;
                else if (source[i] === quote) break;
                i++;
            }
            text = source.slice(start, i + 1);
        } else {
            // scalar (number, true, false, template literal, identifier)
            const lineEnd = source.indexOf('\n', start);
            text = source.slice(start, lineEnd < 0 ? source.length : lineEnd).replace(/;\s*$/, '');
        }
        if (text) out.push({ name, text });
    }
    return out;
}

// ── value → shape ───────────────────────────────────────────────────────────

function shapeOf(value) {
    if (value === UNKNOWN) return { type: 'unknown', value: null };
    if (value === null) return { type: 'null', value: null };
    if (value === undefined) return { type: 'unknown', value: null };
    if (Array.isArray(value)) {
        return { type: 'array', value: value.map(v => shapeOf(v).value) };
    }
    switch (typeof value) {
        case 'boolean':
            return { type: 'bool', value };
        case 'number':
            return { type: Number.isInteger(value) ? 'int' : 'float', value };
        case 'string':
            return { type: 'str', value };
        case 'object': {
            const out = {};
            for (const [k, v] of Object.entries(value)) {
                out[k] = shapeOf(v);
            }
            return { type: 'object', value: out };
        }
        default:
            return { type: 'unknown', value: null };
    }
}

/** Flatten a shape tree into leaf paths. */
function flatten(shape, prefix = [], out = []) {
    if (shape.type === 'object') {
        for (const [k, child] of Object.entries(shape.value)) {
            flatten(child, [...prefix, k], out);
        }
    } else {
        out.push({ path: prefix.join('.'), type: shape.type, value: shape.value });
    }
    return out;
}

/**
 * Paths whose upstream value is an object with no statically-known children.
 *
 * These are free-form maps — `power_user.personas` is keyed by persona name,
 * `oai_settings.extensions` by extension name — so any leaf below one of them
 * is legitimate, and a key checker must not reject it.
 */
function openPaths(shape, prefix = [], out = []) {
    if (shape.type !== 'object') return out;
    const children = Object.entries(shape.value);
    if (children.length === 0) {
        if (prefix.length > 0) out.push(prefix.join('.'));
        return out;
    }
    for (const [k, child] of children) {
        openPaths(child, [...prefix, k], out);
    }
    return out;
}

// ── the surfaces ────────────────────────────────────────────────────────────

// Files whose constants the surfaces may reference. Harvested into the sandbox
// so that e.g. `chatCompletionDefaultPrompts` (imported from PromptManager.js)
// resolves instead of silently vanishing from the inventory.
const CONSTANT_FILES = [
    'public/scripts/power-user.js',
    'public/scripts/openai.js',
    'public/scripts/PromptManager.js',
    'public/scripts/kai-settings.js',
    'public/scripts/nai-settings.js',
    'public/scripts/horde.js',
    'public/scripts/world-info.js',
    'public/scripts/textgen-settings.js',
    'public/scripts/utils.js',
    'public/scripts/constants.js',
];

const SURFACES = [
    { key: 'power_user', file: 'public/scripts/power-user.js', literal: 'power_user' },
    { key: 'oai_settings', file: 'public/scripts/openai.js', literal: 'default_settings' },
    { key: 'kai_settings', file: 'public/scripts/kai-settings.js', literal: 'kai_settings' },
    { key: 'nai_settings', file: 'public/scripts/nai-settings.js', literal: 'nai_settings' },
    { key: 'horde_settings', file: 'public/scripts/horde.js', literal: 'horde_settings' },
];

function buildContext() {
    const ctx = makeContext();
    const known = ctx.__known;
    // Harvest in passes: a constant may reference another constant declared
    // later in the same file, so a second pass picks up what the first missed.
    const pending = [];
    for (const file of CONSTANT_FILES) {
        const full = path.join(ROOT, file);
        if (!fs.existsSync(full)) continue;
        const source = fs.readFileSync(full, 'utf8');
        for (const { name, text } of harvestConstants(source)) {
            pending.push({ name, text });
        }
    }
    for (let pass = 0; pass < 3; pass++) {
        let progress = false;
        for (const { name, text } of pending) {
            if (name in known) continue;
            let value;
            try {
                value = evaluate(ctx, text);
            } catch {
                continue;
            }
            // A value that is entirely UNKNOWN resolved nothing; keep it for a
            // later pass rather than caching a lie.
            if (value === UNKNOWN) continue;
            known[name] = value;
            progress = true;
        }
        if (!progress) break;
    }
    return ctx;
}

function extractSurface({ key, file, literal }) {
    const source = fs.readFileSync(path.join(ROOT, file), 'utf8');
    const text = literalFor(source, literal);
    if (!text) throw new Error(`could not find ${literal} in ${file}`);
    const ctx = buildContext();
    const value = evaluate(ctx, text);
    const shape = shapeOf(value);
    return { key, file, shape };
}

/**
 * `world_info_settings` is not an object literal — it is a function that
 * returns an object of module-level variables (`world-info.js:795`). We take
 * the *names* from the function body and each value from its declaration.
 */
function extractWorldInfo() {
    const file = 'public/scripts/world-info.js';
    const source = fs.readFileSync(path.join(ROOT, file), 'utf8');
    const fnStart = source.indexOf('export function getWorldInfoSettings()');
    if (fnStart < 0) throw new Error('getWorldInfoSettings not found');
    const body = extractBraced(source, source.indexOf('{', fnStart));
    const names = [...body.matchAll(/^\s*([A-Za-z_$][\w$]*)\s*,?\s*$/gm)].map(m => m[1]);
    const ctx = buildContext();
    const shape = { type: 'object', value: {} };
    for (const name of names) {
        let resolved = UNKNOWN;
        try {
            const expr = expressionFor(source, name);
            if (expr) resolved = evaluate(ctx, expr);
        } catch {
            /* unresolved */
        }
        shape.value[name] = shapeOf(resolved);
    }
    return { key: 'world_info_settings', file, shape };
}

/**
 * Maps whose KEYS are data rather than structure.
 *
 * `oai_settings.bias_presets` is keyed by the name of a bias preset
 * ("Anti-bond", "unknown", …), so its children are not settings — they are
 * whatever the operator named their presets. The extractor cannot tell this
 * apart from a fixed object by shape alone: the object has children, so it
 * does not look empty.
 *
 * So the list is curated — but it is CHECKED: every entry must exist in the
 * surface it is claimed for, or the generator fails. A list that can rot
 * silently is worse than no list.
 */
const DATA_KEYED_MAPS = {
    oai_settings: ['bias_presets'],
};

/**
 * `textgenerationwebui_settings` is per-preset, not a literal. The shipped
 * presets in `default/content/presets/textgen/` are the ground truth for
 * which keys exist; the union across all of them is the surface.
 *
 * BUT the presets are only half of it. The CONNECTOR — which backend the
 * account talks to, and where — is not a preset field: it is
 * `textgenerationwebui_settings.type` ("ollama", "llamacpp", "koboldcpp",
 * "vllm", …) and `textgenerationwebui_settings.server_urls` (the URL for each
 * of them), plus the per-backend model names (`ollama_model`,
 * `llamacpp_model`, …). Those live in the settings object itself, in
 * `public/scripts/textgen-settings.js`.
 *
 * Without them the Text Completion backend could not be pointed at a LOCAL
 * inference server from Nix at all:
 * `settings.common.textgenerationwebui_settings.type` was refused by the key
 * guard as "not a setting SillyTavern has", because the inventory had never
 * heard of it.
 *
 * So the literal is read as well, and its keys are added to the preset union.
 * The PRESET value wins where both have a key — a preset is a saved
 * configuration, so its value is the more specific one — and the literal
 * contributes the keys no preset has.
 */
function extractTextGen() {
    const dir = path.join(ROOT, 'default', 'content', 'presets', 'textgen');
    const files = fs.existsSync(dir) ? fs.readdirSync(dir).filter(f => f.endsWith('.json')) : [];
    const merged = {};
    for (const f of files) {
        let parsed;
        try {
            parsed = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
        } catch {
            continue;
        }
        for (const [k, v] of Object.entries(parsed)) {
            if (!(k in merged)) merged[k] = shapeOf(v);
        }
    }

    // The connector fields, from the settings object itself.
    const file = 'public/scripts/textgen-settings.js';
    const source = fs.readFileSync(path.join(ROOT, file), 'utf8');
    const text = literalFor(source, 'textgenerationwebui_settings');
    if (!text) throw new Error('could not find textgenerationwebui_settings in textgen-settings.js');
    const ctx = buildContext();
    const literal = evaluate(ctx, text);
    for (const [k, v] of Object.entries(literal)) {
        if (!(k in merged)) merged[k] = shapeOf(v);
    }

    return {
        key: 'textgenerationwebui_settings',
        file: 'default/content/presets/textgen/*.json + public/scripts/textgen-settings.js',
        shape: { type: 'object', value: merged },
    };
}

/**
 * The 24 top-level keys of `settings.json`, derived from the client's own
 * save payload (public/script.js `saveSettings()`).
 */
function extractTopLevelKeys() {
    const source = fs.readFileSync(path.join(ROOT, 'public', 'script.js'), 'utf8');
    const fnStart = source.indexOf('export async function saveSettings(');
    if (fnStart < 0) throw new Error('saveSettings not found');
    const body = extractBraced(source, source.indexOf('{', fnStart));
    const payloadStart = body.indexOf('const payload = {');
    const payload = extractBraced(body, body.indexOf('{', payloadStart));
    const keys = [...payload.matchAll(/^\s{8}([A-Za-z_$][\w$]*)\s*[:,]/gm)].map(m => m[1]);
    return keys;
}

// ── main ────────────────────────────────────────────────────────────────────

const surfaces = [
    ...SURFACES.map(extractSurface),
    extractWorldInfo(),
    extractTextGen(),
];

const inventory = {
    // The exact source this was derived from, so a reader can tell how old
    // the inventory is.
    generatedFrom: {
        topLevelKeys: 'public/script.js (saveSettings payload)',
        surfaces: surfaces.map(s => `${s.key} <- ${s.file}`),
    },
    topLevelKeys: extractTopLevelKeys(),
    surfaces: Object.fromEntries(
        surfaces.map(s => {
            const fields = flatten(s.shape);
            const auto = openPaths(s.shape);
            const curated = DATA_KEYED_MAPS[s.key] ?? [];
            // A curated entry that no longer exists upstream would leave the
            // tree with a fixed option for a map that is now something else —
            // or with a hole. Either way it is a drift that must be loud.
            for (const path of curated) {
                const prefix = `${path}.`;
                const exists =
                    auto.includes(path) ||
                    fields.some(f => f.path === path || f.path.startsWith(prefix));
                if (!exists) {
                    throw new Error(
                        `DATA_KEYED_MAPS lists "${path}" for ${s.key}, but that path does not exist upstream`,
                    );
                }
            }
            return [
                s.key,
                {
                    file: s.file,
                    fields,
                    openPaths: [...new Set([...auto, ...curated])].sort(),
                },
            ];
        }),
    ),
};

const rendered = JSON.stringify(inventory, null, 2) + '\n';

if (process.argv.includes('--check')) {
    const current = fs.existsSync(OUT) ? fs.readFileSync(OUT, 'utf8') : '';
    if (current !== rendered) {
        console.error(`settings inventory is stale: ${path.relative(ROOT, OUT)} differs from the source`);
        console.error('regenerate: node scripts/extract_settings_inventory.mjs');
        process.exit(1);
    }
    console.log('settings inventory is up to date');
} else {
    fs.mkdirSync(path.dirname(OUT), { recursive: true });
    fs.writeFileSync(OUT, rendered);
    const total = Object.values(inventory.surfaces).reduce((n, s) => n + s.fields.length, 0);
    console.log(`wrote ${path.relative(ROOT, OUT)}`);
    console.log(`  top-level settings.json keys: ${inventory.topLevelKeys.length}`);
    for (const [k, v] of Object.entries(inventory.surfaces)) {
        console.log(`  ${k.padEnd(30)} ${String(v.fields.length).padStart(4)} leaf fields, ${v.openPaths.length} open maps`);
    }
    console.log(`  ${'TOTAL'.padEnd(30)} ${String(total).padStart(4)} leaf fields`);
}
