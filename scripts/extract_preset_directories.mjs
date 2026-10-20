// extract_preset_directories.mjs
//
// Derives the facts the Nix `presets` option group depends on, from
// UPSTREAM'S OWN SOURCE, so that the mapping can be checked rather than
// trusted.
//
// Two facts, and both are load-bearing:
//
//   1. `USER_DIRECTORY_TEMPLATE` in `src/constants.js` — the constant key ->>
//      the per-user directory it holds. The Nix side stores the DIRECTORY
//      name (`TextGen Settings`); this script reports the KEY
//      (`textGen_Settings`) alongside it, so the two can be matched.
//
//   2. `getPresetSettingsByAPI` in `src/endpoints/presets.js` — the API id ->
//      the directory the preset manager reads. This is what decides which
//      backend's presets land where.
//
// Both are read out of the source rather than hard-coded here: a hard-coded
// copy is a second thing to keep in sync, and the whole point of the check
// is to notice when upstream moves.
//
// Usage:
//   node extract_preset_directories.mjs           # print the facts as JSON
//   node extract_preset_directories.mjs --check F # compare against F
//
// The `--check` form exits non-zero and explains the difference, so it can
// be the body of a Nix build.

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');

const read = (relative) => readFileSync(path.join(root, relative), 'utf8');

// ── 1. USER_DIRECTORY_TEMPLATE ───────────────────────────────────────────────

/**
 * Parses the `USER_DIRECTORY_TEMPLATE` object literal out of `src/constants.js`.
 *
 * It is a frozen object literal of `key: 'value'` pairs, so a line-oriented
 * parse is enough — and it fails LOUDLY if the shape changes, which is what
 * we want: a silent parse that returns nothing would make the check pass
 * vacuously.
 *
 * @param {string} source the contents of `src/constants.js`
 * @returns {Record<string, string>} the constant key -> the directory
 */
function parseUserDirectoryTemplate(source) {
    const start = source.indexOf('USER_DIRECTORY_TEMPLATE');
    if (start < 0) {
        throw new Error('src/constants.js: USER_DIRECTORY_TEMPLATE not found.');
    }

    const open = source.indexOf('{', start);
    const close = source.indexOf('});', open);
    if (open < 0 || close < 0) {
        throw new Error('src/constants.js: could not delimit USER_DIRECTORY_TEMPLATE.');
    }

    const body = source.slice(open, close);
    const result = {};

    for (const line of body.split('\n')) {
        const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*'([^']*)'\s*,?\s*$/.exec(line);
        if (match) {
            result[match[1]] = match[2];
        }
    }

    if (Object.keys(result).length === 0) {
        throw new Error('src/constants.js: USER_DIRECTORY_TEMPLATE parsed to nothing.');
    }

    return result;
}

// ── 2. getPresetSettingsByAPI ────────────────────────────────────────────────

/**
 * Parses the API id -> directory-key mapping out of `src/endpoints/presets.js`.
 *
 * The function is a `switch` over the API id where each branch returns
 * `{ folder: directories.<key>, extension: '.json' }`, and several API ids
 * share a branch (`kobold` and `koboldhorde`).
 *
 * @param {string} source the contents of `src/endpoints/presets.js`
 * @returns {Record<string, string>} the API id -> the directory constant key
 */
function parsePresetApiDirectories(source) {
    const start = source.indexOf('getPresetSettingsByAPI');
    if (start < 0) {
        throw new Error('src/endpoints/presets.js: getPresetSettingsByAPI not found.');
    }

    const open = source.indexOf('{', start);
    const close = source.indexOf('\n}', open);
    const body = source.slice(open, close < 0 ? undefined : close);

    const result = {};
    // The API ids collected for the branch currently being read. A branch can
    // list several (`case 'kobold': case 'koboldhorde':`), and they all share
    // the one `return`.
    let pending = [];

    for (const line of body.split('\n')) {
        const caseMatch = /^\s*case\s+'([^']+)'\s*:/.exec(line);
        if (caseMatch) {
            pending.push(caseMatch[1]);
            continue;
        }

        const returnMatch = /return\s*\{\s*folder:\s*directories\.([A-Za-z_][A-Za-z0-9_]*)/.exec(line);
        if (returnMatch) {
            for (const apiId of pending) {
                result[apiId] = returnMatch[1];
            }
            pending = [];
        }
    }

    if (Object.keys(result).length === 0) {
        throw new Error('src/endpoints/presets.js: getPresetSettingsByAPI parsed to nothing.');
    }

    return result;
}

// ── 3. Where each dropdown's LABEL comes from ───────────────────────────────
//
// A preset's label in the UI comes either from its FILE NAME or from a `name`
// field INSIDE the JSON. The module has to know which, because when it is the
// JSON the module fills that field in from the key — and when it is not, it
// must not.
//
// Getting it wrong is silent in the dangerous direction: a bucket whose label
// comes from the JSON but which the module treats as file-named is seeded
// without a `name`, and it appears in the dropdown as "undefined".
//
// So this is read out of the client rather than remembered.

// ── main ─────────────────────────────────────────────────────────────────────

/**
 * Parses the preset-manager's switch to find which API ids take their label
 * from inside the preset object.
 *
 * In `getPresetList`, the file-named presets get their names from the
 * server's `*_setting_names` — which the server built from the file names —
 * while the Advanced Formatting group computes
 * `preset_names = <presets>.map(x => x.name)`.
 *
 * @param {string} source the contents of `public/scripts/preset-manager.js`
 * @returns {string[]} the API ids whose label comes from the content
 */
function parseLabelFromContentApiIds(source) {
    const start = source.indexOf('getPresetList(api)');
    if (start < 0) {
        throw new Error('public/scripts/preset-manager.js: getPresetList not found.');
    }

    const body = source.slice(start, start + 4000);
    const result = [];
    let pending = [];

    for (const line of body.split('\n')) {
        const caseMatch = /^\s*case\s+'([^']+)'\s*:/.exec(line);
        if (caseMatch) {
            pending.push(caseMatch[1]);
            continue;
        }

        if (/preset_names\s*=\s*[\w.]+\.map\(x\s*=>\s*x\.name\)/.test(line)) {
            result.push(...pending);
        }

        if (/^\s*break;/.test(line)) {
            pending = [];
        }
    }

    if (result.length === 0) {
        throw new Error('public/scripts/preset-manager.js: no label-from-content API ids found.');
    }

    return [...new Set(result)].sort();
}

/**
 * @param {string} source
 * @param {string} marker the exact source line that proves the label source
 * @param {string} what what is being checked, for the error message
 * @returns {boolean}
 */
function hasLabelMarker(source, marker, what) {
    if (!source.includes(marker)) {
        throw new Error(`${what}: the marker "${marker}" is not in the source any more.`);
    }
    return true;
}

const facts = {
    template: parseUserDirectoryTemplate(read('src/constants.js')),
    apiTemplateKeys: parsePresetApiDirectories(read('src/endpoints/presets.js')),
    labelFromContent: {
        apiIds: parseLabelFromContentApiIds(read('public/scripts/preset-manager.js')),
        themes: hasLabelMarker(
            read('public/scripts/power-user.js'),
            'option.value = theme.name;',
            'public/scripts/power-user.js (the theme dropdown)',
        ),
        movingUi: hasLabelMarker(
            read('public/scripts/power-user.js'),
            'option.value = movingUIPreset.name;',
            'public/scripts/power-user.js (the Moving UI dropdown)',
        ),
        quickReplies: hasLabelMarker(
            read('public/scripts/extensions/quick-reply/src/QuickReplySet.js'),
            'opt.value = qrs.name;',
            'public/scripts/extensions/quick-reply/src/QuickReplySet.js (the set dropdown)',
        ),
    },
};

const checkIndex = process.argv.indexOf('--check');
if (checkIndex < 0) {
    process.stdout.write(JSON.stringify(facts, null, 2) + '\n');
    process.exit(0);
}

const expectedPath = process.argv[checkIndex + 1];
if (!expectedPath) {
    console.error('extract_preset_directories: --check needs a file to compare against.');
    process.exit(2);
}

const expected = JSON.parse(readFileSync(expectedPath, 'utf8'));

/**
 * Compares two JSON values and returns a list of human-readable differences.
 *
 * @param {any} a
 * @param {any} b
 * @param {string} path
 * @returns {string[]}
 */
function diff(a, b, path = '') {
    if (a === b) {
        return [];
    }

    // Lists are compared ELEMENT BY ELEMENT. Nix's `==` on two lists is an
    // identity check, so two lists with the same contents are not equal, and
    // a naive comparison would report a difference for every list — which is
    // how a check like this ends up failing for a reason nobody can see.
    if (Array.isArray(a) && Array.isArray(b)) {
        const out = [];
        const length = Math.max(a.length, b.length);
        for (let i = 0; i < length; i++) {
            const child = `${path}[${i}]`;
            if (i >= a.length) {
                out.push(`${child}: the module does not have it, upstream has ${JSON.stringify(b[i])}`);
            } else if (i >= b.length) {
                out.push(`${child}: the module has ${JSON.stringify(a[i])}, upstream does not have it`);
            } else {
                out.push(...diff(a[i], b[i], child));
            }
        }
        return out;
    }

    if (Array.isArray(a) !== Array.isArray(b)) {
        return [`${path || '(root)'}: the module has ${JSON.stringify(a)}, upstream has ${JSON.stringify(b)}`];
    }

    const bothObjects = a && b && typeof a === 'object' && typeof b === 'object';

    if (!bothObjects) {
        return [`${path || '(root)'}: the module has ${JSON.stringify(a)}, upstream has ${JSON.stringify(b)}`];
    }

    const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
    const out = [];

    for (const key of keys) {
        const child = path ? `${path}.${key}` : key;
        if (!(key in a)) {
            out.push(`${child}: upstream does not have it, the module does`);
        } else if (!(key in b)) {
            out.push(`${child}: upstream has it, the module does not`);
        } else {
            out.push(...diff(a[key], b[key], child));
        }
    }

    return out;
}

/**
 * Restricts `source` to the keys `wanted` names.
 *
 * The module claims thirteen of upstream's thirty-odd directories, so the
 * comparison is over the module's subset — but a key the module claims that
 * upstream does NOT have is still an error, and `diff` reports it because the
 * restricted value is `undefined` there.
 *
 * @param {Record<string, any>} source
 * @param {Record<string, any>} wanted
 * @returns {Record<string, any>}
 */
function restrict(source, wanted) {
    const out = {};
    for (const key of Object.keys(wanted)) {
        out[key] = source[key];
    }
    return out;
}

const actual = {
    template: restrict(facts.template, expected.template ?? {}),
    apiTemplateKeys: restrict(facts.apiTemplateKeys, expected.apiTemplateKeys ?? {}),
    // The label sources are compared in full: the module declares the same
    // shape, and a difference in either direction matters. A bucket the
    // module treats as file-named but which upstream labels from the content
    // would show its presets as "undefined".
    labelFromContent: facts.labelFromContent,
};

const differences = diff(expected, actual);

if (differences.length > 0) {
    console.error('extract_preset_directories: the module and upstream disagree.');
    console.error('');
    for (const line of differences) {
        console.error(`  ${line}`);
    }
    console.error('');
    console.error('The `presets` option group names these directories, and the server');
    console.error('reads the presets from them. A disagreement means a preset would be');
    console.error('written to a directory the server never reads — a silent failure.');
    console.error('Update lib/default.nix (presetDirectories, presetDirectoryKeys,');
    console.error('presetApiIds) to match upstream.');
    process.exit(1);
}

console.log('PASS preset-directories (the module and upstream agree)');
